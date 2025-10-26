import VideoToolbox
import CoreVideo
import AVFoundation

// VT Error codes
let kVTVideoDecoderBadDataErr: OSStatus = -12785
let kVTInvalidSessionErr: OSStatus = -12909
let kVTVideoDecoderUnsupportedDataFormatErr: OSStatus = -12911
let kVTVideoDecoderMalfunctionErr: OSStatus = -12902

// Define ScrubDirection for this module
enum ScrubDirection {
    case forward
    case backward
    case still
}

/// Phase 3.2: Persistent VTDecompressionSession with async decoding.
/// Maintains one VT session per clip, no reinit in scrub hot path.
actor PersistentVTSession {

    // MARK: - Types

    struct SessionMetrics {
        var created: Int = 0
        var reused: Int = 0
        var asyncEnabled: Bool = false
        var lastCreateTime: CFAbsoluteTime = 0
        var vtErrors: Int = 0
        var rebuilds: Int = 0
        var cacheHits: Int = 0
    }

    struct DecodeResult {
        let pixelBuffer: CVPixelBuffer
        let pts: TimeInterval
        let durationMS: Double
    }

    enum FallbackLevel: Int {
        case hardware = 0
        case proxyOnly = 1      // Intraframe only for 1.5-2s
        case software = 2       // Force software decode
        case imageGenerator = 3 // Last resort fallback
    }

    // MARK: - Properties

    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config

    private var session: VTDecompressionSession?
    private var metrics = SessionMetrics()
    private var pixelBufferPool: CVPixelBufferPool?

    // VT Contract tracking
    private var currentFormatDesc: CMFormatDescription?
    private var consecutiveErrors: Int = 0
    private var useSoftwareDecoder: Bool = false
    private var lastSyncDTS: CMTime = .invalid

    // Fallback ladder & error tracking
    private var fallbackLevel: FallbackLevel = .hardware
    private var fallbackActivatedAt: CFAbsoluteTime = 0
    private var errorTimestamps: [CFAbsoluteTime] = []
    private var rebuildTimestamps: [CFAbsoluteTime] = []
    private var blacklistedRAKeys: Set<String> = []

    // Freeze-gate for anti-thrash
    private var freezeGateUntil: CFAbsoluteTime = 0
    private var lastSwitchTime: CFAbsoluteTime = 0

    // Direction-specific cache
    private var warmFrameCache: [TimeInterval: CVPixelBuffer] = [:]
    private var lastDecodeDirection: ScrubDirection = .still
    private var lastDecodePTS: TimeInterval = 0

    // Decode output tracking - for VT callback
    private struct PendingDecode {
        let startTime: CFAbsoluteTime
        let direction: ScrubDirection
        let continuation: CheckedContinuation<DecodeResult, Error>
        let keys: [Int64]
    }

    private var pendingDecodes: [Int64: PendingDecode] = [:]
    private var decodeQueue = DispatchQueue(label: "vt.decode.queue", qos: .userInitiated)

    private static let outputCallback: VTDecompressionOutputCallback = { refCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
        guard let refCon else { return }
        let session = Unmanaged<PersistentVTSession>.fromOpaque(refCon).takeUnretainedValue()
        Task {
            await session.handleVTCallback(status: status,
                                           infoFlags: infoFlags,
                                           imageBuffer: imageBuffer,
                                           pts: presentationTimeStamp,
                                           duration: presentationDuration)
        }
    }
    
    // MARK: - Initialization
    
    init(formatDescription: CMFormatDescription, clipID: UUID, config: ScrubFeatureFlags.Config) {
        self.currentFormatDesc = formatDescription
        self.clipID = clipID
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Ensures VT session exists, creating if needed.
    func ensureSession() async throws {
        if session != nil {
            metrics.reused += 1
            return
        }
        
        try await createSession()
    }

    /// Returns true when async decode callback path is available.
    func supportsAsyncDecode() -> Bool {
        return config.vtSessionAsync
    }

    func formatSignature() -> String {
        guard let desc = currentFormatDesc else { return "nil" }
        let codec = CMFormatDescriptionGetMediaSubType(desc)
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        return String(format: "%08X:%dx%d", codec, dimensions.width, dimensions.height)
    }

    /// Decodes a sample buffer asynchronously with direction awareness.
    func decode(sampleBuffer: CMSampleBuffer, direction: ScrubDirection = .still) async throws -> DecodeResult {
        // Check freeze-gate
        if CFAbsoluteTimeGetCurrent() < freezeGateUntil {
            let remaining = (freezeGateUntil - CFAbsoluteTimeGetCurrent()) * 1000
            print("[VT_FREEZE_BLOCKED] ms=\(Int(remaining))")
            throw NSError(domain: "PersistentVTSession", code: -100,
                         userInfo: [NSLocalizedDescriptionKey: "Decode blocked by freeze gate"])
        }

        // VT Contract 1: Check for format description change
        guard let newFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NSError(domain: "PersistentVTSession", code: -101,
                         userInfo: [NSLocalizedDescriptionKey: "No format description in sample"])
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)

        // Check warm frame cache first
        if let cachedBuffer = checkWarmFrame(pts: pts.seconds, direction: direction) {
            metrics.cacheHits += 1
            return DecodeResult(pixelBuffer: cachedBuffer, pts: pts.seconds, durationMS: 0)
        }

        if currentFormatDesc == nil || !CMFormatDescriptionEqual(currentFormatDesc!, otherFormatDescription: newFormatDesc) {
            print("[VT_FORMAT_CHANGE] clip=\(clipID) Recreating session due to format change")
            await invalidate()
            currentFormatDesc = newFormatDesc
            metrics.rebuilds += 1
        }

        try await ensureSession()

        guard let session = session else {
            throw NSError(domain: "PersistentVTSession", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "No VT session"])
        }

        let start = CFAbsoluteTimeGetCurrent()

        // VT Contract: Verify sync sample start condition
        var isSync = false
        var dependsOnOthers = false

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isSync = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? false

            if isSync {
                lastSyncDTS = dts.isValid ? dts : pts
            }

            // Enhanced observability
            let codec = extractCodecInfo(from: newFormatDesc)
            let dimensions = extractDimensions(from: newFormatDesc)
            let hwPath = fallbackLevel == .hardware ? "HW" : "SW"

            print("[VT_IN] clip=\(clipID) pts=\(String(format: "%.3f", pts.seconds)) dts=\(String(format: "%.3f", dts.isValid ? dts.seconds : pts.seconds)) sync=\(isSync) depends=\(dependsOnOthers) codec=\(codec) dims=\(dimensions) path=\(hwPath) dir=\(direction)")
        }

        // Use continuation-based async decoding
        return try await withCheckedThrowingContinuation { continuation in
            // Store continuation for callback under all relevant timestamps (PTS/DTS/zero)
            var keys = Set<Int64>()
            let ptsKey = decodeKey(for: pts)
            keys.insert(ptsKey)
            let dtsKey = decodeKey(for: dts)
            if dtsKey != ptsKey {
                keys.insert(dtsKey)
            }
            if ptsKey != 0 {
                keys.insert(0)
            }

            let pending = PendingDecode(startTime: start,
                                        direction: direction,
                                        continuation: continuation,
                                        keys: Array(keys))
            for key in keys {
                pendingDecodes[key] = pending
            }

            // Decode flags - MUST use async for callback to work!
            var infoFlags = VTDecodeInfoFlags()
            let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]

            // Submit frame to VT
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: decodeFlags,
                frameRefcon: Unmanaged.passUnretained(self).toOpaque(),
                infoFlagsOut: &infoFlags
            )

            if status != noErr {
                // Remove pending decode
                removePending(for: pts)

                trackError()
                metrics.vtErrors += 1

                let formatChanged = currentFormatDesc != nil && !CMFormatDescriptionEqual(currentFormatDesc!, otherFormatDescription: newFormatDesc)
                print("[VT_ERR] clip=\(clipID) code=\(status) fdChanged=\(formatChanged) fallback=\(fallbackLevel) lastSyncDTS=\(String(format: "%.3f", lastSyncDTS.isValid ? lastSyncDTS.seconds : -1))")

                // VT Contract: Reset policy for critical errors
                if status == kVTVideoDecoderBadDataErr || status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                    consecutiveErrors += 1
                    print("[VT_RESET] clip=\(clipID) Invalidating session due to error \(status) (consecutive=\(consecutiveErrors))")

                    let now = CFAbsoluteTimeGetCurrent()
                    if status == kVTVideoDecoderMalfunctionErr && fallbackLevel != .software {
                        fallbackLevel = .software
                        fallbackActivatedAt = now
                        print("[VT_FALLBACK] Immediate escalation to Software decode due to malfunction")
                    }

                    Task {
                        await self.invalidate()
                        self.metrics.rebuilds += 1

                        // Escalate through fallback ladder unless we already forced software.
                        do {
                            try await self.escalateFallback()
                        } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                    }
                }

                continuation.resume(throwing: NSError(domain: "PersistentVTSession", code: Int(status),
                                                      userInfo: [NSLocalizedDescriptionKey: "VT decode failed: \(status)"]))
                return
            }

            // Reset error counter on success
            consecutiveErrors = 0

            if infoFlags.contains(.frameDropped) {
                // Remove pending decode
                removePending(for: pts)

                print("[VT_DROPPED] clip=\(clipID) Frame dropped by VT")
                trackError()
                continuation.resume(throwing: NSError(domain: "PersistentVTSession", code: Int(kVTVideoDecoderBadDataErr),
                                                      userInfo: [NSLocalizedDescriptionKey: "VT decode reported frame drop"]))
                return
            }

            // For synchronous decode, manually complete the continuation
            // In a real implementation with callbacks, this would be done in the callback
            // Completion handled in VT output callback
        }
    }

    private func handleVTCallback(status: OSStatus,
                                  infoFlags: VTDecodeInfoFlags,
                                  imageBuffer: CVImageBuffer?,
                                  pts: CMTime,
                                  duration: CMTime) async {
        let baseKey = decodeKey(for: pts)
        var resolved: PendingDecode?
        for candidate in [baseKey, baseKey - 1, baseKey + 1] {
            if let entry = pendingDecodes[candidate] {
                resolved = entry
                break
            }
        }

        if resolved == nil, let first = pendingDecodes.first?.value {
            resolved = first
        }

        guard let resolved else {
            let seconds = pts.isValid ? pts.seconds : -1
            print("[VT_CALLBACK] Missing continuation for pts=\(String(format: "%.3f", seconds)) status=\(status) baseKey=\(baseKey)")
            return
        }

        for key in resolved.keys {
            pendingDecodes.removeValue(forKey: key)
        }

        let finish: (Error) -> Void = { error in
            resolved.continuation.resume(throwing: error)
        }

        if status != noErr {
            trackError()
            finish(NSError(domain: "PersistentVTSession",
                           code: Int(status),
                           userInfo: [NSLocalizedDescriptionKey: "VT callback reported error: \(status)"]))
            return
        }

        if infoFlags.contains(.frameDropped) {
            trackError()
            finish(NSError(domain: "PersistentVTSession",
                           code: Int(kVTVideoDecoderBadDataErr),
                           userInfo: [NSLocalizedDescriptionKey: "VT callback dropped frame"]))
            return
        }

        guard let imageBuffer else {
            trackError()
            finish(NSError(domain: "PersistentVTSession",
                           code: -4,
                           userInfo: [NSLocalizedDescriptionKey: "VT callback delivered nil image buffer"]))
            return
        }

        let pixelBuffer = imageBuffer as CVPixelBuffer
        let elapsedMS = (CFAbsoluteTimeGetCurrent() - resolved.startTime) * 1000
        let seconds = pts.seconds

        lastDecodePTS = seconds
        lastDecodeDirection = resolved.direction
        cacheWarmFrame(pixelBuffer: pixelBuffer, pts: seconds, direction: resolved.direction)

        resolved.continuation.resume(returning: DecodeResult(pixelBuffer: pixelBuffer,
                                                             pts: seconds,
                                                             durationMS: elapsedMS))
    }
    
    /// Invalidates the session (call when clip changes).
    func invalidate() async {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        pixelBufferPool = nil
        consecutiveErrors = 0
        warmFrameCache.removeAll()
        failPendingDecodes(code: -998, message: "VT session invalidated")
    }

    func flushAndReset() {
        if let session = session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        pixelBufferPool = nil
        warmFrameCache.removeAll()
        failPendingDecodes(code: -997, message: "VT session reset")
    }

    /// Activates freeze gate for specified duration
    func activateFreezeGate(duration: TimeInterval = 0.15) {
        freezeGateUntil = CFAbsoluteTimeGetCurrent() + duration
        lastSwitchTime = CFAbsoluteTimeGetCurrent()
        print("[VT_FREEZE_GATE] Activated for \(Int(duration * 1000))ms")
    }

    /// Blacklists an RA key that caused errors
    func blacklistRAKey(_ key: String) {
        blacklistedRAKeys.insert(key)
        print("[VT_RA_BLACKLIST] Added key: \(key)")
    }

    /// Checks if RA key is blacklisted
    func isRAKeyBlacklisted(_ key: String) -> Bool {
        return blacklistedRAKeys.contains(key)
    }
    
    /// Returns current metrics for telemetry.
    func getMetrics() -> SessionMetrics {
        return metrics
    }
    
    // MARK: - Private Methods
    
    /// Creates a new VT decompression session with proper contract.
    private func createSession() async throws {
        let start = CFAbsoluteTimeGetCurrent()

        // Check rebuild limit (max 5 in 500ms)
        let now = CFAbsoluteTimeGetCurrent()
        rebuildTimestamps.append(now)
        rebuildTimestamps = rebuildTimestamps.filter { now - $0 < 0.5 }

        if rebuildTimestamps.count > 5 {
            print("[VT_REBUILD_LIMIT] Exceeded rebuild limit, escalating fallback")
            try await escalateFallback()
            rebuildTimestamps.removeAll()
        }

        // Pixel buffer attributes for zero-copy
        let pixelFormat: OSType = {
            switch fallbackLevel {
            case .proxyOnly:
                // Use 422 format for proxy/intraframe
                return kCVPixelFormatType_422YpCbCr8
            default:
                return config.pixelFormat
            }
        }()

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: 1920,  // Will be overridden by actual dimensions
            kCVPixelBufferHeightKey as String: 1080
        ]

        // VT Contract: Decoder specification based on fallback level
        var decoderSpec: [String: Any] = [:]

        switch fallbackLevel {
        case .hardware:
            // Allow hardware with fallback
            decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = true
            decoderSpec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] = false

        case .software:
            // Force software decode
            decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = false

        case .proxyOnly:
            // Use hardware for intraframe codecs
            decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = true

        case .imageGenerator:
            // This level doesn't use VT at all
            throw NSError(domain: "PersistentVTSession", code: -999,
                         userInfo: [NSLocalizedDescriptionKey: "ImageGenerator fallback - VT not available"])
        }

        // Create VT session
        guard let formatDesc = currentFormatDesc else {
            throw NSError(domain: "PersistentVTSession", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "No format description available"])
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec as CFDictionary?,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let newSession = newSession else {
            throw NSError(domain: "PersistentVTSession", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create VT session: \(status)"])
        }

        // VT Contract: Set session properties
        // Note: AllowFrameReordering is not available on macOS, it's iOS only
        // We handle frame reordering through proper DTS/PTS management

        // RealTime mode based on context
        let realTimeMode = config.vtSessionAsync
        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: realTimeMode ? kCFBooleanTrue : kCFBooleanFalse
        )

        // Thread count for performance
        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_ThreadCount,
            value: 2 as CFNumber
        )
        
        session = newSession
        metrics.created += 1
        metrics.asyncEnabled = supportsAsyncDecode()
        metrics.lastCreateTime = CFAbsoluteTimeGetCurrent()
        
        let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000
        
        // Capture metrics before MainActor
        let currentMetrics = metrics
        
        await MainActor.run {
            // TEMP: Always log for debugging
            ScrubTelemetry.shared.logVTSession(ScrubTelemetry.VTSessionLog(
                timestamp: CFAbsoluteTimeGetCurrent(),
                clipID: clipID,
                created: currentMetrics.created,
                reused: currentMetrics.reused,
                asyncEnabled: currentMetrics.asyncEnabled,
                durationMS: duration
            ))
        }
    }

    // MARK: - Helper Methods

    /// Tracks error timestamps for rate limiting
    private func trackError() {
        let now = CFAbsoluteTimeGetCurrent()
        errorTimestamps.append(now)
        // Keep only errors from last 500ms
        errorTimestamps = errorTimestamps.filter { now - $0 < 0.5 }
    }

    private func failPendingDecodes(code: Int, message: String) {
        guard !pendingDecodes.isEmpty else { return }
        let error = NSError(domain: "PersistentVTSession", code: code,
                            userInfo: [NSLocalizedDescriptionKey: message])
        var resumed: Set<Int64> = []
        for (_, pending) in pendingDecodes {
            let masterKey = pending.keys.min() ?? Int64.min
            if resumed.insert(masterKey).inserted {
                pending.continuation.resume(throwing: error)
            }
        }
        pendingDecodes.removeAll()
    }

    private func decodeKey(for time: CMTime) -> Int64 {
        guard time.isValid else { return Int64.min }
        let scaled = CMTimeConvertScale(time, timescale: 1000, method: .default)
        return scaled.value
    }

    private func removePending(for time: CMTime) {
        let key = decodeKey(for: time)
        guard let pending = pendingDecodes.removeValue(forKey: key) else { return }
        for alias in pending.keys where alias != key {
            pendingDecodes.removeValue(forKey: alias)
        }
    }

    /// Escalates through the fallback ladder
    private func escalateFallback() async throws {
        let now = CFAbsoluteTimeGetCurrent()

        // Check error rate (≥3 errors in 500ms triggers escalation)
        if errorTimestamps.count >= 3 {
            switch fallbackLevel {
            case .hardware:
                fallbackLevel = .proxyOnly
                fallbackActivatedAt = now
                print("[VT_FALLBACK] Escalating to ProxyOnly mode for 1.5-2s")

            case .proxyOnly:
                // Check if we've been in proxy mode long enough
                if now - fallbackActivatedAt > 2.0 {
                    fallbackLevel = .software
                    print("[VT_FALLBACK] Escalating to Software decode")
                }

            case .software:
                fallbackLevel = .imageGenerator
                print("[VT_FALLBACK] Escalating to ImageGenerator (last resort)")

            case .imageGenerator:
                print("[VT_FALLBACK] Already at maximum fallback level")
            }

            // Clear error tracking after escalation
            errorTimestamps.removeAll()
        }

        // Auto-recovery: Return to hardware after proxy timeout
        if fallbackLevel == .proxyOnly && now - fallbackActivatedAt > 2.0 {
            fallbackLevel = .hardware
            print("[VT_FALLBACK] Returning to hardware decode")
        }
    }

    /// Checks warm frame cache with direction-specific rules
    private func checkWarmFrame(pts: TimeInterval, direction: ScrubDirection) -> CVPixelBuffer? {
        guard let cached = warmFrameCache[pts] else { return nil }

        let tolerance: TimeInterval = 0.0005 // 0.5ms tolerance

        switch direction {
        case .backward:
            // Backwards: no future frames as warm (only ≤ target+tol)
            if pts <= lastDecodePTS + tolerance {
                return cached
            }

        case .forward:
            // Forward: no past frames as warm (only ≥ target-tol)
            if pts >= lastDecodePTS - tolerance {
                return cached
            }

        case .still:
            // Still: nearest PTS is acceptable
            return cached
        }

        return nil
    }

    /// Caches warm frame for potential reuse
    private func cacheWarmFrame(pixelBuffer: CVPixelBuffer, pts: TimeInterval, direction: ScrubDirection) {
        // Limit cache size
        if warmFrameCache.count > 10 {
            // Remove furthest frame from current position
            if let furthest = warmFrameCache.keys.max(by: { abs($0 - pts) < abs($1 - pts) }) {
                warmFrameCache.removeValue(forKey: furthest)
            }
        }

        warmFrameCache[pts] = pixelBuffer
    }

    /// Extracts codec info from format description
    private func extractCodecInfo(from formatDesc: CMFormatDescription) -> String {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)

        switch mediaSubType {
        case kCMVideoCodecType_H264:
            return "H264"
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        case kCMVideoCodecType_AppleProRes422:
            return "ProRes422"
        case kCMVideoCodecType_AppleProRes4444:
            return "ProRes4444"
        default:
            return String(format: "0x%08X", mediaSubType)
        }
    }

    /// Extracts dimensions from format description
    private func extractDimensions(from formatDesc: CMFormatDescription) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        return "\(dimensions.width)x\(dimensions.height)"
    }
}
