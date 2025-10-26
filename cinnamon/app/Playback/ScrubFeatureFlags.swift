import Foundation
import CoreVideo

/// Feature flags for scrub pipeline optimizations.
/// Allows incremental rollout and A/B testing of Phase 3 (Core) and Phase 2 (Minimal-Set).
@MainActor
final class ScrubFeatureFlags {
    static let shared = ScrubFeatureFlags()
    
    // MARK: - Phase 3: Core (Fundamental Latency Reduction)
    
    /// 3.1: Persistent ScrubReader mit Sliding Window (default: aktiviert)
    var persistentScrubReader: Bool = true
    
    /// 3.2: Persistent VTDecompressionSession (async, no reinit in hot path)
    var persistentVTSession: Bool = true
    
    /// 3.3: Keyframe-seek with minimal preroll (IDR + 8-12 frames)
    var minimalPreroll: Bool = true
    
    /// 3.4: Zero-copy & format path (direct 420v decode, pools)
    var zeroCopyPath: Bool = true

    /// Experimental: compressed-sample scrub engine with VT-managed decoding
    var compressedScrubEngine: Bool = true

    /// Phase 1 core: reverse forward-feed to guarantee monotonic VT ordering
    var reverseForwardFeed: Bool = true
    var reverseForwardFeedAVC: Bool = true
    var reverseForwardFeedHEVC: Bool = true

    /// Phase 2: Bad-data retry & dedupe loop
    var decoderBadDataRetry: Bool = true
    
    // MARK: - Phase 2: Minimal-Set (Smoothness & Anti-Thrash)
    
    /// 2.1: GOP-based coalescing & retarget (game-changer)
    var gopCoalescing: Bool = true
    
    /// 2.2: Velocity-based target prediction (t_pred)
    var velocityPrediction: Bool = true
    
    /// 2.3: Reverse/Forward landing zones (LZ)
    var landingZones: Bool = true
    
    /// 2.4: History-first & byte-budget cache
    var historyFirst: Bool = true
    
    /// 2.5: Admission control & direction-sensitive gates
    var admissionControl: Bool = true
    
    /// 2.6: STOP/Deadline decode (exact frame ≤66ms)
    var deadlineDecode: Bool = true
    
    // MARK: - Configuration
    
    struct Config {
        // Phase 3 config
        var scrubReaderWindow: TimeInterval = 1.0  // ±0.5s around t_pred
        var vtSessionAsync: Bool = true
        var prerollFrames: Int = 2  // Ultra-minimal preroll for maximum speed (was 10)
        var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var poolWarmCount: Int = 8
        
        // Phase 2 config
        var predictionFactor: Double = 0.12  // 120ms lookahead
        var predictionClampMin: TimeInterval = -0.5
        var predictionClampMax: TimeInterval = 0.5
        var velocityEMAAlpha: Double = 0.3  // Exponential moving average
        var velocityHysteresis: TimeInterval = 0.175  // 175ms
        
        var reverseLZFrames: Int = 5  // Frames behind t_pred (FIX A: ≥3 für VT Vorlauf)
        var forwardLZFrames: Int = 2  // Frames ahead t_pred
        var adaptiveLZMultiplier: Double = 0.5  // velocity_fps * 0.5
        var adaptiveLZMin: Int = 2
        var adaptiveLZMax: Int = 12
        
        var cacheBytesBudget: Int = 200 * 1024 * 1024  // 200MB
        var cacheBiasFrames: Int = 5  // ±5 frames around t_pred
        var reverseHistoryFrames: Int = 16  // Keep at least ~0.7s history behind
        var reverseHistorySlackFrames: Int = 4  // Extra slack added to abs(lead)
        var reverseHistoryMaxWindow: TimeInterval = 0.9  // Cap reverse history retention window
        var forwardHistoryWindow: TimeInterval = 0.12  // Keep limited past for forward scrub
        var historyScrubPriorityBoost: Double = 4000  // Lower eviction score for scrub frames
        var historyByteWeight: Double = 0.0000015  // Byte-size impact during eviction

        var maxInFlightPerClip: Int = 8  // Increased for smoother reverse scrubbing
        var maxInFlightBurstPerClip: Int = 6  // Allow more burst for direction changes
        var burstDuration: TimeInterval = 0.3  // Slightly longer burst window
        var maxConcurrentDecodes: Int = 10  // More concurrent decodes for better parallelism
        var reverseGlobalSlack: Int = 3  // Extra global slots for hot reverse decodes
        var reverseClipSlack: Int = 1  // Extra per-clip slots when reverse decode hängt
        var reverseRescueThreshold: TimeInterval = 0.25  // Sekunden bis Rettungsslot
        var reverseCriticalSlotsPerClip: Int = 2  // Critical reverse slots per clip
        var reverseRepairSlotCapacity: Int = 2  // Erhöht für bessere Repair-Performance
        var reverseDeadlineSlotCapacity: Int = 2  // Erhöht für Deadline-Decodes

        var admissionNeverCancelRunning: Bool = true

        var forwardMinInterval: TimeInterval = 0.033  // 33ms (~30 Hz) for smoother forward
        var reverseMinInterval: TimeInterval = 0.008  // 8ms (~120fps) for smooth reverse
        var reverseVelocityFreeThreshold: Double = 2.0  // Lower threshold for opening gate
        var useEqualityFix: Bool = true  // >= instead of > (CRITICAL for proper gating)
        var reverseRateGateOverrideCount: Int = 3  // consecutive denials before override
        var reverseRateGateOverrideCooldown: TimeInterval = 0.18  // cooldown between overrides
        var reverseMaxPrimaryLead: TimeInterval = 0.60  // Allow up to 600ms late frames during reverse scrubbing
        var reverseFutureLeadCap: TimeInterval = 0.35   // Skip/suppress frames more than 350ms ahead during reverse scrubbing
        var reverseFutureBackoff: TimeInterval = 0.5    // When future frame detected, rewind requests by 500ms
        var reverseWatchdogTimeout: TimeInterval = 0.60
        var reverseWatchdogCancelTasks: Bool = false

        var reverseFailureRecoveryThreshold: Int = 2
        var reverseFailureBackoff: TimeInterval = 0.18
        var reverseFailureMaxBackoff: TimeInterval = 0.75
        var reverseProxyErrorThreshold: Int = 3
        var reverseProxyOverrideLifespan: TimeInterval = 3.0

        var compressedIdrTargetGate: TimeInterval = 0.5

        var mandatoryDecodeEnabled: Bool = true
        var mandatoryDecodeMaxRetries: Int = 3

        var decoderBadDataRetryEnabled: Bool = true
        var decoderBadDataMaxAttempts: Int = 3
        
        var stopIdleThreshold: TimeInterval = 0.2  // 200ms idle = STOP
        var stopDeadlineTarget: TimeInterval = 0.066  // 66ms = 1-2 draws
        var stopBackfillWindow: TimeInterval = 0.5  // ±0.5s after stop
    }
    
    var config = Config()
    static let stableReverseScrub = true
    
    // MARK: - Telemetry
    
    var telemetryEnabled: Bool = true
    var verboseLogging: Bool = true  // TEMP: Verbose logging aktiviert
    
    // MARK: - Helpers
    
    /// Returns true if all Phase 3 features are enabled
    var phase3Enabled: Bool {
        persistentScrubReader && persistentVTSession && minimalPreroll && zeroCopyPath
    }
    
    /// Returns true if all Phase 2 features are enabled
    var phase2Enabled: Bool {
        gopCoalescing && velocityPrediction && landingZones && historyFirst && admissionControl && deadlineDecode
    }
    
    /// Returns true if all features are enabled
    var allFeaturesEnabled: Bool {
        phase3Enabled && phase2Enabled
    }
    
    private init() {
        // Load from environment variables if present
        loadFromEnvironment()
        sanitizeConfig()
    }

    private func loadFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        
        // Phase 3
        if let val = env["SCRUB_PERSISTENT_READER"] { persistentScrubReader = val == "1" }
        if let val = env["SCRUB_PERSISTENT_VT"] { persistentVTSession = val == "1" }
        if let val = env["SCRUB_MINIMAL_PREROLL"] { minimalPreroll = val == "1" }
        if let val = env["SCRUB_ZERO_COPY"] { zeroCopyPath = val == "1" }
        if let val = env["SCRUB_COMPRESSED_ENGINE"] { compressedScrubEngine = val == "1" }
        if let val = env["SCRUB_REVERSE_FORWARD_FEED"] { reverseForwardFeed = val != "0" }
        if let val = env["SCRUB_RFF_AVC"] { reverseForwardFeedAVC = val != "0" }
        if let val = env["SCRUB_RFF_HEVC"] { reverseForwardFeedHEVC = val != "0" }
        if let val = env["SCRUB_BAD_DATA_RETRY"] { decoderBadDataRetry = val != "0" }
        if let val = env["SCRUB_BAD_DATA_RETRY_ENABLED"] {
            config.decoderBadDataRetryEnabled = val != "0"
        }
        if let val = env["SCRUB_BAD_DATA_MAX_ATTEMPTS"], let attempts = Int(val) {
            config.decoderBadDataMaxAttempts = attempts
        }
        
        // Phase 2
        if let val = env["SCRUB_GOP_COALESCE"] { gopCoalescing = val == "1" }
        if let val = env["SCRUB_VELOCITY_PRED"] { velocityPrediction = val == "1" }
        if let val = env["SCRUB_LANDING_ZONES"] { landingZones = val == "1" }
        if let val = env["SCRUB_HISTORY_FIRST"] { historyFirst = val == "1" }
        if let val = env["SCRUB_ADMISSION"] { admissionControl = val == "1" }
        if let val = env["SCRUB_DEADLINE"] { deadlineDecode = val == "1" }
        
        // Telemetry
        if let val = env["SCRUB_TELEMETRY"] ?? env["CIN_SCRUB_TELEMETRY"] {
            telemetryEnabled = val != "0"
        }
        if let val = env["SCRUB_VERBOSE"] ?? env["CIN_SCRUB_VERBOSE"] {
            verboseLogging = val != "0"
        }
    }

    private func sanitizeConfig() {
        config.maxInFlightPerClip = max(config.maxInFlightPerClip, 2)
        config.maxInFlightBurstPerClip = max(config.maxInFlightBurstPerClip, config.maxInFlightPerClip)
        config.maxConcurrentDecodes = max(config.maxConcurrentDecodes, config.maxInFlightPerClip)
        config.reverseGlobalSlack = max(0, config.reverseGlobalSlack)
        config.reverseClipSlack = max(1, config.reverseClipSlack)
        config.reverseRescueThreshold = max(0, config.reverseRescueThreshold)
        config.reverseCriticalSlotsPerClip = max(1, config.reverseCriticalSlotsPerClip)
        config.reverseRepairSlotCapacity = max(1, config.reverseRepairSlotCapacity)
        config.reverseDeadlineSlotCapacity = max(1, config.reverseDeadlineSlotCapacity)
        config.compressedIdrTargetGate = max(0, config.compressedIdrTargetGate)
        config.mandatoryDecodeMaxRetries = max(1, config.mandatoryDecodeMaxRetries)
        config.decoderBadDataMaxAttempts = max(1, config.decoderBadDataMaxAttempts)
        config.reverseFutureLeadCap = max(0.05, config.reverseFutureLeadCap)
        config.reverseFutureBackoff = max(0.05, config.reverseFutureBackoff)
        config.reverseFailureRecoveryThreshold = max(1, config.reverseFailureRecoveryThreshold)
        config.reverseFailureBackoff = max(0.05, config.reverseFailureBackoff)
        config.reverseFailureMaxBackoff = max(config.reverseFailureBackoff, config.reverseFailureMaxBackoff)
    }

    func isReverseForwardFeedEnabled(for codec: GOPAnalyzer.Codec) -> Bool {
        guard reverseForwardFeed else { return false }
        switch codec {
        case .avc:
            return reverseForwardFeedAVC
        case .hevc:
            return reverseForwardFeedHEVC
        }
    }

    func isBadDataRetryEnabled() -> Bool {
        decoderBadDataRetry && config.decoderBadDataRetryEnabled
    }
    
    func printStatus() {
        print("=== Scrub Feature Flags ===")
        print("Phase 3 (Core): \(phase3Enabled ? "✅" : "❌")")
        print("  - Persistent Reader: \(persistentScrubReader ? "✅" : "❌")")
        print("  - Persistent VT: \(persistentVTSession ? "✅" : "❌")")
        print("  - Minimal Preroll: \(minimalPreroll ? "✅" : "❌")")
        print("  - Zero Copy: \(zeroCopyPath ? "✅" : "❌")")
        print("  - Compressed Engine: \(compressedScrubEngine ? "✅" : "❌")")
        print("")
        print("Phase 2 (Minimal-Set): \(phase2Enabled ? "✅" : "❌")")
        print("  - GOP Coalescing: \(gopCoalescing ? "✅" : "❌")")
        print("  - Velocity Prediction: \(velocityPrediction ? "✅" : "❌")")
        print("  - Landing Zones: \(landingZones ? "✅" : "❌")")
        print("  - History First: \(historyFirst ? "✅" : "❌")")
        print("  - Admission Control: \(admissionControl ? "✅" : "❌")")
        print("  - Deadline Decode: \(deadlineDecode ? "✅" : "❌")")
        print("")
        print("All Features: \(allFeaturesEnabled ? "✅ ENABLED" : "❌ PARTIAL")")
        print("===========================")
    }
}
