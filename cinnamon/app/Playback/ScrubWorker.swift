import Foundation
import CoreVideo
import AVFoundation

/// Per-clip worker that performs GOP-aware chunk decoding with landing zones.
/// Runs in low-priority queue to avoid blocking main thread during scrubbing.
actor ScrubWorker {
    
    // MARK: - Types
    
    struct Configuration {
        let reverseLandingZoneFrames: Int = 2  // frames behind t_pred
        let forwardLandingZoneFrames: Int = 2  // frames ahead of t_pred
        let gopChunkSize: Int = 10  // frames per GOP chunk
        let maxInFlight: Int = 1  // max concurrent decodes per clip
        let forwardMinInterval: TimeInterval = 0.050  // 50ms
        let reverseMinInterval: TimeInterval = 0.030  // 30ms
    }
    
    // MARK: - Properties
    
    private let clipID: UUID
    private let source: VideoSource
    private let config: Configuration
    private var currentEpoch: UInt64 = 0
    private var currentGOPKey: TimeInterval?
    private var decodeTask: Task<Void, Never>?
    private var inFlightPTS: Set<TimeInterval> = []
    private var lastDecodeTime: CFAbsoluteTime = 0
    private var isActive: Bool = false
    private var currentTarget: TimeInterval = 0
    private var currentDirection: ScrubCoordinator.ScrubDirection = .forward
    
    // MARK: - Initialization
    
    init(clipID: UUID, source: VideoSource, config: Configuration = Configuration()) {
        self.clipID = clipID
        self.source = source
        self.config = config
    }
    
    // MARK: - Lifecycle
    
    /// Starts the worker with specified epoch and target.
    func start(epoch: UInt64, target: TimeInterval, direction: ScrubCoordinator.ScrubDirection) {
        currentEpoch = epoch
        currentTarget = target
        currentDirection = direction
        isActive = true
        
        print("[ScrubWorker] Starting worker for clip \(clipID.uuidString.prefix(8)) at t=\(String(format: "%.3f", target))s, epoch=\(epoch)")
        
        // Start decode loop in background
        decodeTask = Task.detached(priority: .utility) { [weak self] in
            await self?.decodeLoop()
        }
    }
    
    /// Retargets the worker to a new position without restarting if within same GOP.
    func retarget(newTarget: TimeInterval, direction: ScrubCoordinator.ScrubDirection) {
        currentTarget = newTarget
        currentDirection = direction
        
        // GOP coalescing will be handled in decode loop
    }
    
    /// Stops the worker, optionally allowing brief backfill.
    func stop(allowBackfill: Bool) {
        isActive = false
        decodeTask?.cancel()
        decodeTask = nil
        inFlightPTS.removeAll()
        currentGOPKey = nil
    }
    
    /// Performs ungated deadline decode for exact frame at specified time.
    func deadlineDecode(at time: TimeInterval, epoch: UInt64) async {
        guard epoch == currentEpoch else { return }
        
        let decodeStart = CFAbsoluteTimeGetCurrent()
        
        do {
            if let frame = try await source.copyFrame(at: time, caller: "ScrubWorker-deadline", version: epoch) {
                // Cache frame immediately
                await MainActor.run {
                    TransportController.shared.cacheFrame(
                        frame.pixelBuffer,
                        clipID: clipID,
                        presentationTime: frame.timelineTime,
                        version: epoch,
                        origin: .scrub,
                        storeInPrimary: true
                    )
                }
                
                let duration = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                
                await MainActor.run {
                    ScrubTelemetry.shared.logDecode(ScrubTelemetry.DecodeLog(
                        timestamp: CFAbsoluteTimeGetCurrent(),
                        pts: frame.timelineTime,
                        durationMS: duration,
                        reason: "deadline",
                        epoch: epoch
                    ))
                }
            }
        } catch {
            print("[ScrubWorker] Deadline decode failed for clip \(clipID): \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    /// Main decode loop that runs while worker is active.
    /// CRITICAL: Workers are DISABLED during active scrubbing to prevent stale frames.
    /// They only activate during the brief pause after scrubbing ends (deadline decode).
    private func decodeLoop() async {
        print("[ScrubWorker] Decode loop started for clip \(clipID.uuidString.prefix(8))")
        print("[ScrubWorker] ⚠️ Worker decode loop is DISABLED during active scrubbing")
        print("[ScrubWorker] Workers only perform deadline decode when scrubbing ends")
        
        // Workers are intentionally idle during active scrubbing
        // The main scrubSeek path handles frame loading via actuallyUpdateFrameBuffer
        // Workers only activate for deadline decode (exact frame after scrub ends)
        
        while isActive && !Task.isCancelled {
            // Sleep and wait for deadline decode requests
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms idle sleep
        }
        
        print("[ScrubWorker] Decode loop ended for clip \(clipID.uuidString.prefix(8))")
    }
    
    /// Calculates the landing zone range based on target and direction.
    private func calculateLandingZone(target: TimeInterval, direction: ScrubCoordinator.ScrubDirection) -> ClosedRange<TimeInterval> {
        // Get frame duration from source (assume 24fps if unknown)
        let frameDuration = 1.0 / 24.0  // TODO: Get actual frame duration from source
        
        switch direction {
        case .reverse:
            // Reverse: keep frames BEHIND target
            let start = target - (Double(config.reverseLandingZoneFrames) * frameDuration)
            let end = target
            return start...end
            
        case .forward:
            // Forward: keep frames AHEAD of target
            let start = target
            let end = target + (Double(config.forwardLandingZoneFrames) * frameDuration)
            return start...end
        }
    }
    
    /// Decodes frames within the landing zone range.
    private func decodeLandingZone(range: ClosedRange<TimeInterval>) async {
        let frameDuration = 1.0 / 24.0  // TODO: Get actual frame duration
        let frameCount = Int(ceil((range.upperBound - range.lowerBound) / frameDuration))
        
        // Capture epoch at start of decode batch
        let batchEpoch = currentEpoch
        
        for i in 0..<frameCount {
            guard isActive && !Task.isCancelled else { break }
            
            let pts = range.lowerBound + (Double(i) * frameDuration)
            
            // Check if already in flight
            guard !inFlightPTS.contains(pts) else { continue }
            
            // Check history first
            if await checkHistory(pts: pts) {
                continue
            }
            
            // Apply rate-gating with >= operator (equality fix)
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - lastDecodeTime
            let minInterval = currentDirection == .forward ? config.forwardMinInterval : config.reverseMinInterval
            
            guard elapsed >= minInterval else {
                await MainActor.run {
                    ScrubTelemetry.shared.logCoalesce(ScrubTelemetry.CoalesceLog(
                        timestamp: now,
                        minIntervalMS: minInterval * 1000,
                        sinceLastMS: elapsed * 1000,
                        decision: "skip",
                        equalityFix: true
                    ))
                }
                continue
            }
            
            // Check admission control
            guard inFlightPTS.count < config.maxInFlight else { continue }
            
            // Decode frame
            inFlightPTS.insert(pts)
            lastDecodeTime = now
            
            let decodeStart = CFAbsoluteTimeGetCurrent()
            
            do {
                if let frame = try await source.copyFrame(at: pts, caller: "ScrubWorker-lz", version: batchEpoch) {
                    // Check epoch before caching - ensure this batch is still current
                    guard batchEpoch == currentEpoch else {
                        inFlightPTS.remove(pts)
                        print("[ScrubWorker] Discarding stale frame: batch epoch \(batchEpoch) != current \(currentEpoch)")
                        continue
                    }
                    
                    // Cache frame
                    await MainActor.run {
                        TransportController.shared.cacheFrame(
                            frame.pixelBuffer,
                            clipID: clipID,
                            presentationTime: frame.timelineTime,
                            version: batchEpoch,
                            origin: .scrub,
                            storeInPrimary: false
                        )
                    }
                    
                    let duration = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                    
                    await MainActor.run {
                        ScrubTelemetry.shared.logDecode(ScrubTelemetry.DecodeLog(
                            timestamp: CFAbsoluteTimeGetCurrent(),
                            pts: frame.timelineTime,
                            durationMS: duration,
                            reason: "lz",
                            epoch: batchEpoch
                        ))
                    }
                }
            } catch {
                print("[ScrubWorker] Decode failed for clip \(clipID) at pts=\(pts): \(error)")
            }
            
            inFlightPTS.remove(pts)
        }
    }
    
    /// Checks if frame exists in history/cache.
    /// Returns true if frame is available, false if decode needed.
    private func checkHistory(pts: TimeInterval) async -> Bool {
        // Check if frame exists in TransportController's frame history
        let exists = await MainActor.run {
            TransportController.shared.pixelBufferSync(for: clipID, at: pts) != nil
        }
        
        if exists {
            await MainActor.run {
                ScrubTelemetry.shared.logHistoryCheck(ScrubTelemetry.HistoryCheckLog(
                    timestamp: CFAbsoluteTimeGetCurrent(),
                    clipID: clipID,
                    time: pts,
                    hit: true,
                    ringFillPercent: 0.0  // TODO: Get actual ring fill
                ))
            }
        }
        
        return exists
    }
}
