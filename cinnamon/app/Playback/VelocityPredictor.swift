import Foundation

/// Sample of velocity at a specific timestamp (shared type)
struct VelocitySample {
    let timestamp: CFAbsoluteTime
    let velocity: Double
}

/// Phase 2.2: Velocity-based target prediction.
/// Predicts where the user is scrubbing to, not where they are now.
/// FIX B: Proper EMA smoothing across multiple scrubSeek events.
@MainActor
final class VelocityPredictor {
    
    // MARK: - Types
    
    struct Prediction {
        let tNow: TimeInterval
        let tPred: TimeInterval
        let velocityFPS: Double
        let smoothedVelocity: Double
        let windowFrames: Int
    }
    
    // MARK: - Properties
    
    private let config: ScrubFeatureFlags.Config
    private var velocityHistory: [VelocitySample] = []
    private var smoothedVelocity: Double = 0
    private var lastUpdateTime: CFAbsoluteTime = 0
    private var lastTimelineTime: TimeInterval = 0
    
    // MARK: - Initialization
    
    init(config: ScrubFeatureFlags.Config) {
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Updates velocity and returns prediction.
    /// FIX B: Calculate instantaneous velocity from Δtimeline/Δhost, then apply EMA.
    func predict(tNow: TimeInterval, rawVelocity: Double) -> Prediction {
        let now = CFAbsoluteTimeGetCurrent()
        
        // Calculate instantaneous velocity from actual timeline movement
        let instantVelocity: Double
        if lastUpdateTime > 0 && now > lastUpdateTime {
            let deltaTimeline = tNow - lastTimelineTime
            let deltaHost = now - lastUpdateTime
            // Convert to fps: timeline seconds per host second
            instantVelocity = deltaTimeline / deltaHost
        } else {
            instantVelocity = rawVelocity
        }
        
        // Add to history
        velocityHistory.append(VelocitySample(timestamp: now, velocity: instantVelocity))
        
        // Trim old samples (keep last 200ms for smoothing window)
        let cutoff = now - config.velocityHysteresis
        velocityHistory.removeAll { $0.timestamp < cutoff }
        
        // Calculate smoothed velocity using EMA
        // FIX B: α≈0.3 for responsive but smooth tracking
        if smoothedVelocity == 0 || velocityHistory.count == 1 {
            smoothedVelocity = instantVelocity
        } else {
            smoothedVelocity = (config.velocityEMAAlpha * instantVelocity) + 
                              ((1.0 - config.velocityEMAAlpha) * smoothedVelocity)
        }
        
        // Calculate predicted target
        // FIX B: t_pred = t_now + clamp(velocity_fps * 0.12, -0.5s, +0.5s)
        var offset = smoothedVelocity * config.predictionFactor
        var clampMin = config.predictionClampMin
        if smoothedVelocity < -0.5 {
            clampMin = max(clampMin, -0.35)
        }
        if smoothedVelocity < -1.0 {
            clampMin = max(clampMin, -0.30)
        }
        let clampedOffset = min(max(offset, clampMin), config.predictionClampMax)
        let tPred = tNow + clampedOffset
        
        // Calculate adaptive window size for landing zones
        // FIX B: W = clamp(|velocity_fps|*0.5, 2, 12) frames
        let absVelocity = abs(smoothedVelocity)
        let adaptiveFrames = Int(absVelocity * config.adaptiveLZMultiplier)
        var windowFrames = min(max(adaptiveFrames, config.adaptiveLZMin), config.adaptiveLZMax)
        if smoothedVelocity <= -0.4 {
            windowFrames = max(windowFrames, 6)
        }
        if smoothedVelocity <= -0.8 {
            windowFrames = max(windowFrames, 8)
        }
        
        lastUpdateTime = now
        lastTimelineTime = tNow
        
        // Log prediction with enhanced telemetry
        // TEMP: Always log for debugging
        ScrubTelemetry.shared.logPrediction(ScrubTelemetry.PredictionLog(
            timestamp: now,
            tNow: tNow,
            tPred: tPred,
            velocityFPS: smoothedVelocity,
            windowFrames: windowFrames
        ))
        
        return Prediction(
            tNow: tNow,
            tPred: tPred,
            velocityFPS: instantVelocity,
            smoothedVelocity: smoothedVelocity,
            windowFrames: windowFrames
        )
    }
    
    /// Resets the predictor state.
    func reset() {
        velocityHistory.removeAll()
        smoothedVelocity = 0
        lastUpdateTime = 0
    }
}
