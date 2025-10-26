import Foundation

/// Phase 2.3: Reverse/Forward landing zones.
/// Keeps 1-2 frames warm around t_pred, prioritizing correct end based on direction.
@MainActor
final class LandingZoneManager {
    
    // MARK: - Types
    
    struct LandingZone {
        let tPred: TimeInterval
        let direction: ScrubCoordinator.ScrubDirection
        let behindRange: ClosedRange<TimeInterval>  // Frames behind t_pred
        let aheadRange: ClosedRange<TimeInterval>   // Frames ahead t_pred
        let windowFrames: Int
        let frameDuration: TimeInterval
        let repairMode: Bool
        let repairDelta: TimeInterval?
    }
    
    // MARK: - Properties
    
    private let config: ScrubFeatureFlags.Config
    
    // MARK: - Initialization
    
    init(config: ScrubFeatureFlags.Config) {
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Calculates landing zone around t_pred based on velocity and direction.
    /// FIX B: Accept pre-calculated adaptive window from VelocityPredictor for consistency.
    func calculateLandingZone(tPred: TimeInterval,
                              velocityFPS: Double,
                              direction: ScrubCoordinator.ScrubDirection,
                              frameDuration: TimeInterval,
                              adaptiveWindowFrames: Int? = nil,
                              recentDecodeDelta: TimeInterval? = nil,
                              currentTime: TimeInterval? = nil) -> LandingZone {
        let safeFrameDuration = max(frameDuration, 1e-6)
        let normalizedTPred = max(tPred, 0.0)
        let normalizedNow = max(currentTime ?? tPred, 0.0)
        // Use pre-calculated window from VelocityPredictor if available
        let windowFrames: Int
        if let adaptiveFrames = adaptiveWindowFrames {
            windowFrames = adaptiveFrames
        } else {
            // Fallback: calculate adaptive window size based on velocity
            let absVelocity = abs(velocityFPS)
            let adaptiveFrames = Int(absVelocity * config.adaptiveLZMultiplier)
            windowFrames = min(max(adaptiveFrames, config.adaptiveLZMin), config.adaptiveLZMax)
        }
        
        // Calculate ranges based on direction
        var behindRange: ClosedRange<TimeInterval>
        var aheadRange: ClosedRange<TimeInterval>
        var behindFramesComputed = 0
        var effectiveWindowFrames = windowFrames
        
        let baseWindowFrames = max(config.reverseLZFrames, config.forwardLZFrames)
        let targetWindowFrames = max(windowFrames, baseWindowFrames)
        let maxWarmWindow: TimeInterval = max(0.020, safeFrameDuration * Double(targetWindowFrames))
        let maxFrameRatio = (maxWarmWindow / safeFrameDuration) + 1e-6
        let maxFramesPerWindow = max(targetWindowFrames, Int(maxFrameRatio.rounded(.down)))

        var repairMode = false
        let repairDelta: TimeInterval?
        if let delta = recentDecodeDelta, abs(delta) > safeFrameDuration * 0.75 {
            repairDelta = abs(delta)
        } else {
            repairDelta = nil
        }

        switch direction {
        case .reverse:
            // Reverse: prioritize frames BEHIND t_pred
            if StableScrubMode.enabled {
                let absVelocity = abs(velocityFPS)
                let desiredBehind = max(8, min(12, Int(absVelocity * 10.0)))
                let behindFrames = max(desiredBehind, 8)
                let aheadFrames = 1

                let behindStart = max(0.0, normalizedTPred - Double(behindFrames) * safeFrameDuration)
                let aheadEnd = normalizedTPred + Double(aheadFrames) * safeFrameDuration

                behindRange = behindStart...normalizedTPred
                aheadRange = normalizedTPred...aheadEnd
                effectiveWindowFrames = max(behindFrames, aheadFrames)
                behindFramesComputed = behindFrames
            } else {
                let rawBehindFrames = max(windowFrames, config.reverseLZFrames)
                let behindFrames = max(1, min(rawBehindFrames, maxFramesPerWindow))
                let aheadFrames = min(max(windowFrames, config.forwardLZFrames), maxFramesPerWindow)

                let behindStart = max(0.0, normalizedTPred - Double(behindFrames) * safeFrameDuration)
                let aheadEnd = normalizedTPred + Double(aheadFrames) * safeFrameDuration

                behindRange = behindStart...normalizedTPred
                aheadRange = normalizedTPred...aheadEnd
                effectiveWindowFrames = max(behindFrames, aheadFrames)
                behindFramesComputed = behindFrames
            }

        case .forward:
            // Forward: prioritize frames AHEAD of t_pred
            let rawAheadFrames = max(windowFrames, config.forwardLZFrames)
            let aheadFrames = max(1, min(rawAheadFrames, maxFramesPerWindow))
            let behindFrames = min(max(config.reverseLZFrames, 1), maxFramesPerWindow)

            let behindStart = max(0.0, normalizedTPred - Double(behindFrames) * safeFrameDuration)
            let aheadEnd = normalizedTPred + Double(aheadFrames) * safeFrameDuration

            behindRange = behindStart...normalizedTPred
            aheadRange = normalizedTPred...aheadEnd
        }

        if direction == .reverse,
           let repairDelta,
           repairDelta > safeFrameDuration * 0.75 {
            let additionalFrames = max(1, Int(ceil(repairDelta / safeFrameDuration)))
            let desiredBehind = min(maxFramesPerWindow,
                                     max(behindFramesComputed, config.reverseLZFrames + additionalFrames * 2))
            if desiredBehind > behindFramesComputed {
                let behindStart = max(0.0, normalizedTPred - Double(desiredBehind) * safeFrameDuration)
                behindRange = behindStart...normalizedTPred
                behindFramesComputed = desiredBehind
                effectiveWindowFrames = max(effectiveWindowFrames, desiredBehind)
                repairMode = true
            } else {
                repairMode = behindFramesComputed > config.reverseLZFrames
            }
        }

        // Log landing zone
        // TEMP: Always log for debugging
        let warmBehind = Int((normalizedTPred - behindRange.lowerBound) / safeFrameDuration)
        let warmAhead = Int((aheadRange.upperBound - normalizedTPred) / safeFrameDuration)

        ScrubTelemetry.shared.logReverseLZ(ScrubTelemetry.ReverseLZLog(
            timestamp: CFAbsoluteTimeGetCurrent(),
            tNow: normalizedNow,
            tPred: normalizedTPred,
            warmBehind: warmBehind,
            warmAhead: warmAhead,
            repairActive: repairMode,
            repairFrames: behindFramesComputed
        ))

        return LandingZone(
            tPred: normalizedTPred,
            direction: direction,
            behindRange: behindRange,
            aheadRange: aheadRange,
            windowFrames: effectiveWindowFrames,
            frameDuration: safeFrameDuration,
            repairMode: repairMode,
            repairDelta: repairDelta
        )

    }

    /// Returns priority-ordered list of PTS values to decode for landing zone.
    func getPriorityPTS(landingZone: LandingZone) -> [TimeInterval] {
        var pts: [TimeInterval] = []
        
        let frameDuration = landingZone.frameDuration
        let epsilon = frameDuration * 0.25

        switch landingZone.direction {
        case .reverse:
            // Reverse: prioritize frames behind t_pred (in reverse order)
            let behindSpan = max(landingZone.tPred - landingZone.behindRange.lowerBound, 0)
            let behindCount = max(0, Int(floor((behindSpan + epsilon) / frameDuration)))
            if behindCount > 0 {
                for i in 0..<behindCount {
                    let time = landingZone.tPred - Double(i) * frameDuration
                    if time >= landingZone.behindRange.lowerBound {
                        pts.append(time)
                    }
                }
            }
            
            // Then frames ahead
            let aheadSpan = max(landingZone.aheadRange.upperBound - landingZone.tPred, 0)
            let aheadCount = max(0, Int(floor((aheadSpan + epsilon) / frameDuration)))
            if aheadCount > 0 {
                for i in 1...aheadCount {
                    let time = landingZone.tPred + Double(i) * frameDuration
                    if time <= landingZone.aheadRange.upperBound {
                        pts.append(time)
                    }
                }
            }
            
        case .forward:
            // Forward: prioritize frames ahead of t_pred
            let aheadSpan = max(landingZone.aheadRange.upperBound - landingZone.tPred, 0)
            let aheadCount = max(0, Int(floor((aheadSpan + epsilon) / frameDuration)))
            if aheadCount > 0 {
                for i in 0..<aheadCount {
                    let time = landingZone.tPred + Double(i) * frameDuration
                    if time <= landingZone.aheadRange.upperBound {
                        pts.append(time)
                    }
                }
            }
            
            // Then frames behind (in reverse order)
            let behindSpan = max(landingZone.tPred - landingZone.behindRange.lowerBound, 0)
            let behindCount = max(0, Int(floor((behindSpan + epsilon) / frameDuration)))
            if behindCount > 0 {
                for i in 1...behindCount {
                    let time = landingZone.tPred - Double(i) * frameDuration
                    if time >= landingZone.behindRange.lowerBound {
                        pts.append(time)
                    }
                }
            }
        }
        
        return pts
    }
    
    /// Checks if PTS is within landing zone.
    func isInLandingZone(_ pts: TimeInterval, landingZone: LandingZone) -> Bool {
        return landingZone.behindRange.contains(pts) || landingZone.aheadRange.contains(pts)
    }
}
