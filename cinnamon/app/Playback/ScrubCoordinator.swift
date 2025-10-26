import Foundation
import CoreVideo

/// Coordinates scrub operations across multiple video sources with predictive frame pre-warming.
/// Manages scrub lifecycle, velocity tracking, and worker coordination for smooth forward/reverse scrubbing.
@MainActor
final class ScrubCoordinator {
    
    // MARK: - Types
    
    enum ScrubState: Equatable {
        case idle
        case fast      // |velocity| > 30 fps
        case medium    // 10 fps < |velocity| ≤ 30 fps
        case slow      // |velocity| ≤ 10 fps
    }
    
    enum ScrubDirection: Equatable {
        case forward
        case reverse
    }
    
    struct ScrubMetrics {
        var velocity: Double  // fps
        var direction: ScrubDirection
        var state: ScrubState
        var epoch: UInt64
        
        init(velocity: Double = 0, direction: ScrubDirection = .forward, state: ScrubState = .idle, epoch: UInt64 = 0) {
            self.velocity = velocity
            self.direction = direction
            self.state = state
            self.epoch = epoch
        }
    }
    
    // MARK: - Properties
    
    private(set) var currentEpoch: UInt64 = 0
    private(set) var metrics: ScrubMetrics = ScrubMetrics()
    private var workers: [UUID: ScrubWorker] = [:]
    private var velocityHistory: CircularBuffer<VelocitySample> = CircularBuffer(capacity: 20)
    private var lastStateChangeTime: CFAbsoluteTime = 0
    private let stateChangeHysteresis: TimeInterval = 0.175  // 175ms hysteresis
    
    // Prediction constants
    private let predictionFactor: Double = 0.12  // 120ms lookahead
    private let minPredictionOffset: TimeInterval = -0.5
    private let maxPredictionOffset: TimeInterval = 0.5
    
    // Velocity thresholds
    private let fastThreshold: Double = 30.0
    private let mediumThreshold: Double = 10.0
    
    // MARK: - Lifecycle
    
    /// Begins a new scrub operation, incrementing the epoch and starting workers for visible clips.
    /// - Parameters:
    ///   - time: Current timeline time
    ///   - clips: Dictionary of clip IDs to VideoSource instances for visible clips
    func beginScrub(at time: TimeInterval, clips: [UUID: VideoSource]) {
        print("[ScrubCoordinator] beginScrub called with \(clips.count) clips")
        
        // Increment epoch to invalidate any in-flight operations from previous scrub
        currentEpoch &+= 1
        
        // Reset metrics
        metrics = ScrubMetrics(
            velocity: 0,
            direction: .forward,
            state: .idle,
            epoch: currentEpoch
        )
        
        // Clear velocity history
        velocityHistory = CircularBuffer(capacity: 20)
        lastStateChangeTime = CFAbsoluteTimeGetCurrent()
        
        // Start workers for each visible clip
        for (clipID, source) in clips {
            print("[ScrubCoordinator] Creating worker for clip \(clipID.uuidString.prefix(8))")
            let worker = ScrubWorker(clipID: clipID, source: source)
            workers[clipID] = worker
            
            Task {
                print("[ScrubCoordinator] Starting worker for clip \(clipID.uuidString.prefix(8))")
                await worker.start(epoch: currentEpoch, target: time, direction: .forward)
            }
        }
        
        print("[ScrubCoordinator] beginScrub at t=\(String(format: "%.3f", time))s, epoch=\(currentEpoch), clips=\(clips.count)")
    }
    
    /// Updates scrub position and velocity, retargeting workers as needed.
    /// - Parameters:
    ///   - time: Current timeline time
    ///   - velocity: Current scrub velocity in fps (negative for reverse)
    func updateScrub(at time: TimeInterval, velocity: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        
        // Record velocity sample
        velocityHistory.append(VelocitySample(timestamp: now, velocity: velocity))
        
        // Update velocity with hysteresis
        let (smoothedVelocity, direction, state) = updateVelocityWithHysteresis(newVelocity: velocity, now: now)
        
        // Update metrics
        metrics.velocity = smoothedVelocity
        metrics.direction = direction
        metrics.state = state
        
        // Calculate predicted target
        let predictedTarget = calculatePredictedTarget(current: time, velocity: smoothedVelocity)
        
        // Retarget all workers
        for worker in workers.values {
            Task {
                await worker.retarget(newTarget: predictedTarget, direction: direction)
            }
        }
    }
    
    /// Ends the scrub operation, performing deadline decode for exact frame at final position.
    /// - Parameter time: Final timeline time
    func endScrub(at time: TimeInterval) async {
        print("[ScrubCoordinator] endScrub at t=\(String(format: "%.3f", time))s, epoch=\(currentEpoch)")
        
        let stopStart = CFAbsoluteTimeGetCurrent()
        
        // Perform deadline decode (ungated) for exact frame
        await deadlineDecode(at: time)
        
        let stopDuration = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
        
        // Log stop metric
        ScrubTelemetry.shared.logStopMetric(ScrubTelemetry.StopMetricLog(
            timestamp: CFAbsoluteTimeGetCurrent(),
            direction: metrics.direction,
            timeToExactFrameMS: stopDuration
        ))
        
        // Stop all workers with brief backfill allowed
        for worker in workers.values {
            Task {
                await worker.stop(allowBackfill: true)
            }
        }
        
        // Clear workers
        workers.removeAll()
        
        // Reset metrics to idle
        metrics.state = .idle
        metrics.velocity = 0
    }
    
    // MARK: - Private Methods
    
    /// Calculates predicted target time based on current time and velocity.
    /// Uses formula: t_pred = t_now + clamp(velocity * predictionFactor, min, max)
    private func calculatePredictedTarget(current: TimeInterval, velocity: Double) -> TimeInterval {
        let offset = velocity * predictionFactor
        let clampedOffset = min(max(offset, minPredictionOffset), maxPredictionOffset)
        return current + clampedOffset
    }
    
    /// Updates velocity with hysteresis to prevent rapid state changes.
    /// Returns smoothed velocity, direction, and state.
    private func updateVelocityWithHysteresis(newVelocity: Double, now: CFAbsoluteTime) -> (velocity: Double, direction: ScrubDirection, state: ScrubState) {
        // Get recent velocity samples (within last 200ms)
        let recentSamples = velocityHistory.recent(within: 0.2, now: now)
        
        // Calculate average velocity from recent samples
        let avgVelocity: Double
        if recentSamples.isEmpty {
            avgVelocity = newVelocity
        } else {
            let sum = recentSamples.reduce(0.0) { $0 + $1.velocity }
            avgVelocity = sum / Double(recentSamples.count)
        }
        
        // Determine direction
        let direction: ScrubDirection = avgVelocity < 0 ? .reverse : .forward
        
        // Determine state based on absolute velocity
        let absVelocity = abs(avgVelocity)
        let newState: ScrubState
        if absVelocity > fastThreshold {
            newState = .fast
        } else if absVelocity > mediumThreshold {
            newState = .medium
        } else {
            newState = .slow
        }
        
        // Apply hysteresis: only change state if enough time has passed
        let timeSinceLastChange = now - lastStateChangeTime
        let finalState: ScrubState
        if newState != metrics.state && timeSinceLastChange >= stateChangeHysteresis {
            finalState = newState
            lastStateChangeTime = now
            
            // Log state change
            ScrubTelemetry.shared.logScrub(ScrubTelemetry.ScrubLog(
                timestamp: now,
                state: finalState,
                direction: direction,
                velocityFPS: avgVelocity,
                epoch: currentEpoch
            ))
        } else {
            finalState = metrics.state
        }
        
        return (avgVelocity, direction, finalState)
    }
    
    /// Performs ungated deadline decode for exact frame at specified time.
    /// Ensures frame is available within 66ms.
    private func deadlineDecode(at time: TimeInterval) async {
        // Deadline decode bypasses all rate-gating and admission control
        // Each worker performs immediate decode for exact PTS
        await withTaskGroup(of: Void.self) { group in
            for worker in workers.values {
                group.addTask {
                    await worker.deadlineDecode(at: time, epoch: self.currentEpoch)
                }
            }
        }
    }
}

// MARK: - Supporting Types
// Note: VelocitySample is now defined in VelocityPredictor.swift

/// Circular buffer for storing fixed-capacity time-series data
struct CircularBuffer<T> {
    private var buffer: [T]
    private var writeIndex: Int = 0
    private let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }
    
    mutating func append(_ element: T) {
        if buffer.count < capacity {
            buffer.append(element)
        } else {
            buffer[writeIndex] = element
            writeIndex = (writeIndex + 1) % capacity
        }
    }
    
    /// Returns elements within specified duration from now
    func recent(within duration: TimeInterval, now: CFAbsoluteTime) -> [T] where T == VelocitySample {
        let cutoff = now - duration
        return buffer.filter { $0.timestamp >= cutoff }
    }
}
