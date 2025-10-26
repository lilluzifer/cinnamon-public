import AVFoundation
import CoreVideo

enum ScrubReaderError: Error {
    case decodeFailed(code: Int?)

    var code: Int? {
        switch self {
        case .decodeFailed(let value):
            return value
        }
    }
}

/// Phase 3.1: Persistent ScrubReader with sliding window.
/// Maintains a single AVAssetReader per clip with a movable window around t_pred.
/// No reader rebuild per scrubSeek - only window shifts.
actor PersistentScrubReader {
    
    // MARK: - Types
    
    struct WindowMetrics {
        var shifts: Int = 0
        var rebuilds: Int = 0
        var lastShiftTime: CFAbsoluteTime = 0
        var lastRebuildTime: CFAbsoluteTime = 0
    }

    private struct ReaderWindow {
        var raKey: RAKey?
        var start: TimeInterval
        var end: TimeInterval

        var range: ClosedRange<TimeInterval> { start...end }
    }
    
    // MARK: - Properties

    private let asset: AVAsset
    private let vtDecoderBadDataCode = -12785
    private let track: AVAssetTrack
    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config
    private let codec: GOPAnalyzer.Codec
    private let trackMediaSubType: FourCharCode
    private let frameDuration: TimeInterval
    private let assetDuration: TimeInterval
    private let analyzer: GOPAnalyzer
    private var lastSlideTargetMs: Int64 = .min
    private let minSlideDeltaMs: Int64 = 200
    private var coalescedSlideCount = 0
    private var recenterFreezeUntil: CFAbsoluteTime = 0

    // Proxy/Mezzanine policy
    private var isProxyMode: Bool = false
    private var proxyActivatedAt: CFAbsoluteTime = 0
    private let proxyHysteresisDuration: TimeInterval = 1.5 // 1.5-2s hysteresis
    private var isIntraframeCodec: Bool = false

    // VT Session for decoding (injected from EnhancedScrubDecoder)
    private var vtSession: PersistentVTSession?

    // Reader state management with synchronization
    private var readerLock = NSLock()
    private var isReaderInUse = false

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var currentWindow: ReaderWindow?
    private var activeReaderRange: ClosedRange<TimeInterval>?
    private var metrics = WindowMetrics()
    private var lastWindowIDR: TimeInterval?
    private var lastReaderErrorCode: Int?
    private var lastRandomAccess: GOPAnalyzer.RandomAccessResult?
    private var rebuildTimestamps: [CFAbsoluteTime] = []
    private let epsilon: TimeInterval = 0.010
    
    // Format-change detection & error recovery
    private var lastFormatDesc: CMFormatDescription?
    private var consecutiveReadFailures: Int = 0
    private var consecutiveFormatChanges: Int = 0
    private let maxConsecutiveFailures = 3
    private var lastDecodePTS: TimeInterval = 0
    
    // MARK: - Initialization
    
    init(asset: AVAsset,
         track: AVAssetTrack,
         clipID: UUID,
         frameDuration: TimeInterval,
         config: ScrubFeatureFlags.Config,
         codec: GOPAnalyzer.Codec,
         analyzer: GOPAnalyzer) {
        self.asset = asset
        self.track = track
        self.clipID = clipID
        self.frameDuration = frameDuration
        self.config = config
        self.codec = codec
        self.assetDuration = PersistentScrubReader.deriveDuration(for: asset)
        self.analyzer = analyzer

        var detectedSubType: FourCharCode = 0
        if let formatDescAny = track.formatDescriptions.first {
            let formatDesc = formatDescAny as! CMFormatDescription
            detectedSubType = CMFormatDescriptionGetMediaSubType(formatDesc)

            switch detectedSubType {
            case kCMVideoCodecType_AppleProRes422,
                 kCMVideoCodecType_AppleProRes422HQ,
                 kCMVideoCodecType_AppleProRes422LT,
                 kCMVideoCodecType_AppleProRes422Proxy,
                 kCMVideoCodecType_AppleProRes4444:
                isIntraframeCodec = true
            default:
                break
            }
        }

        trackMediaSubType = detectedSubType
    }
    
    // MARK: - Public Methods

    /// Sets the VT session for hardware decoding
    func setVTSession(_ session: PersistentVTSession?) {
        readerLock.lock()
        defer { readerLock.unlock() }

        self.vtSession = session
        if session != nil {
            print("[READER_VT] VT Session connected for clip \(clipID)")
            // Mark reader for rebuild on next use (but don't invalidate immediately)
            currentWindow = nil  // Force rebuild on next access
        }
    }

    /// Check if VT session is set
    func hasVTSession() -> Bool {
        return vtSession != nil
    }

    /// Ensures window covers the predicted target, shifting if needed.
    /// Only rebuilds if clip/stream params change.
    func ensureWindow(around tPred: TimeInterval,
                      randomAccess: GOPAnalyzer.RandomAccessResult?,
                      targetPTS: TimeInterval,
                      preroll: ClosedRange<TimeInterval>?,
                      manualRange: ClosedRange<TimeInterval>? = nil) async throws {
        lastRandomAccess = randomAccess
        if let ra = randomAccess, ra.kind != .none {
            lastWindowIDR = ra.pts
        } else {
            lastWindowIDR = nil
        }

        if let manualRange {
            try await rebuildReader(range: manualRange,
                                    around: tPred,
                                    raKey: randomAccess?.key)
            return
        }

        if StableScrubMode.enabled,
           let ra = randomAccess,
           ra.kind != .none {
            try await ensureStableWindow(randomAccess: ra,
                                         tPred: tPred,
                                         targetPTS: targetPTS,
                                         preroll: preroll)
            return
        }

        if try await applySafeWindowIfNeeded(tPred: tPred,
                                              targetPTS: targetPTS,
                                              randomAccess: randomAccess) {
            return
        }

        var desiredRange = computeWindowRange(tPred: tPred,
                                              randomAccess: randomAccess,
                                              targetPTS: targetPTS,
                                              preroll: preroll)
        // Preserve IDR if we have one for H.264/HEVC
        let shouldPreserveIDR = (codec == .avc || codec == .hevc) && randomAccess != nil && randomAccess!.kind != .none
        desiredRange = expandRange(desiredRange, center: tPred, preserveIDR: shouldPreserveIDR)
        try await rebuildReader(range: desiredRange,
                                around: tPred,
                                raKey: randomAccess?.key)
    }

    private func applySafeWindowIfNeeded(tPred: TimeInterval,
                                         targetPTS: TimeInterval,
                                         randomAccess: GOPAnalyzer.RandomAccessResult?) async throws -> Bool {
        guard let ra = randomAccess else { return false }
        let tPredMs = Int64((tPred * 1000.0).rounded())
        let targetMs = Int64((targetPTS * 1000.0).rounded())
        let nearPred = await analyzer.isNearCut(absMs: tPredMs, track: track)
        let nearTarget = await analyzer.isNearCut(absMs: targetMs, track: track)
        let nearCut = nearPred || nearTarget
        let raChanged = currentWindow?.raKey != ra.key
        guard nearCut || raChanged else { return false }
        guard let prevMs = await analyzer.prevSyncAbsMs(before: tPredMs, track: track) else { return false }
        let centerMs = max(prevMs + 120, tPredMs - 220)
        let safeStartMs = max(centerMs - 500, 0)
        let safeEndMs = centerMs + 500
        let safeRange = Double(safeStartMs) / 1000.0...Double(safeEndMs) / 1000.0
        if let window = currentWindow {
            let delta = abs(window.start - safeRange.lowerBound) + abs(window.end - safeRange.upperBound)
            if delta < 0.01 {
                return false
            }
        }
        print("[READER_SAFE_WINDOW] start=\(safeRange.lowerBound) end=\(safeRange.upperBound)")
        try await rebuildReader(range: safeRange,
                                around: tPred,
                                raKey: ra.key)
        return true
    }

    private func ensureStableWindow(randomAccess: GOPAnalyzer.RandomAccessResult,
                                    tPred: TimeInterval,
                                    targetPTS: TimeInterval,
                                    preroll: ClosedRange<TimeInterval>?) async throws {
        let anchorPTS = max(randomAccess.pts, 0)
        let prerollStart = preroll.map { min($0.lowerBound, anchorPTS) }
        let leadIn = idrLeadInDuration
        let desiredStart = max(0.0, (prerollStart ?? anchorPTS) - leadIn)

        let forwardAnchor = max(tPred, targetPTS)
        let reorderHead = Double(reorderLeadFrameCount()) * frameDuration
        var desiredEnd = max(forwardAnchor + reorderHead, desiredStart + minimumWindowSpan)
        if let upper = preroll?.upperBound {
            desiredEnd = max(desiredEnd, upper)
        }
        desiredEnd = max(desiredEnd, forwardAnchor + frameDuration * 2.0)
        if assetDuration.isFinite {
            desiredEnd = min(desiredEnd, assetDuration)
        }

        print("[READER_STABLE] IDR at \(String(format: "%.3f", anchorPTS)), window [\(String(format: "%.3f", desiredStart)), \(String(format: "%.3f", desiredEnd))] target=\(String(format: "%.3f", targetPTS))")

        let desiredWindow = ReaderWindow(raKey: randomAccess.key,
                                         start: desiredStart,
                                         end: desiredEnd)

        if var window = currentWindow,
           let currentKey = window.raKey,
           currentKey.epoch == randomAccess.key.epoch,
           overlaps(window, tPred: tPred) {

            let needsBackwardExpansion = desiredStart < (activeReaderRange?.lowerBound ?? desiredStart) - epsilon
            let needsForwardExpansion = desiredEnd > (activeReaderRange?.upperBound ?? desiredEnd) + epsilon

            if needsBackwardExpansion || needsForwardExpansion {
                let combinedStart = min(desiredStart, activeReaderRange?.lowerBound ?? desiredStart)
                let combinedEnd = max(desiredEnd, activeReaderRange?.upperBound ?? desiredEnd)
                // Preserve IDR start for H.264/HEVC
                let normalized = normalizeRange(combinedStart...combinedEnd, center: tPred, preserveIDRStart: (codec == .avc || codec == .hevc))
                try await rebuildReader(range: normalized,
                                        around: tPred,
                                        raKey: randomAccess.key)
                return
            }

            var didSlide = false
            if abs(window.start - desiredWindow.start) > epsilon {
                window.start = desiredWindow.start
                didSlide = true
            }
            if desiredWindow.end > window.end + epsilon {
                window.end = desiredWindow.end
                didSlide = true
            }

            window.raKey = randomAccess.key
            currentWindow = window
            activeReaderRange = window.start...window.end
            
            if didSlide {
                metrics.shifts += 1
                metrics.lastShiftTime = CFAbsoluteTimeGetCurrent()
                let snapshot = window
                let shiftCount = metrics.shifts
                let rebuildCount = metrics.rebuilds
                Task { @MainActor in
                    if ScrubFeatureFlags.shared.verboseLogging {
                        print("[SCRUB_READER] slide window=[\(String(format: "%.3f", snapshot.start)),\(String(format: "%.3f", snapshot.end))] shifts=\(shiftCount) rebuilds=\(rebuildCount)")
                    }
                }
            }
            return
        }

        // Preserve IDR start for H.264/HEVC
        let normalized = normalizeRange(desiredWindow.range, center: tPred, preserveIDRStart: (codec == .avc || codec == .hevc))
        try await rebuildReader(range: normalized,
                                around: tPred,
                                raKey: randomAccess.key)
    }
    
    /// Copies frame at specified PTS using current reader.
    func copyFrame(at pts: TimeInterval) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        try await ensureReaderReady(for: pts)
        return try await readFrame(at: pts, allowRetry: true)
    }
    
    /// Invalidates the reader (call when clip changes).
    func invalidate() async {
        reader?.cancelReading()
        reader = nil
        output = nil
        currentWindow = nil
        lastWindowIDR = nil
        lastRandomAccess = nil
        activeReaderRange = nil
        lastReaderErrorCode = nil
        rebuildTimestamps.removeAll()
        metrics = WindowMetrics()
        lastSlideTargetMs = .min
        
        // Reset format tracking & error counters
        lastFormatDesc = nil
        consecutiveReadFailures = 0
        consecutiveFormatChanges = 0
    }

    /// Returns current metrics for telemetry.
    func getMetrics() -> WindowMetrics {
        return metrics
    }

    func formatSignature() -> String {
        if let desc = lastFormatDesc {
            let codec = CMFormatDescriptionGetMediaSubType(desc)
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            return String(format: "%08X:%dx%d", codec, dims.width, dims.height)
        }
        if let formatDescriptions = track.formatDescriptions as? [CMFormatDescription],
           let trackDesc = formatDescriptions.first {
            let codec = CMFormatDescriptionGetMediaSubType(trackDesc)
            let dims = CMVideoFormatDescriptionGetDimensions(trackDesc)
            return String(format: "%08X:%dx%d", codec, dims.width, dims.height)
        }
        return "nil"
    }

    func freezeRecentering(for duration: TimeInterval = 0.15, reason: String) {
        recenterFreezeUntil = CFAbsoluteTimeGetCurrent() + duration
        print("[READER_FREEZE] ms=\(Int(duration * 1000)) reason=\(reason)")
    }

    /// Activates proxy mode with hysteresis
    func activateProxyMode() {
        if !isProxyMode {
            isProxyMode = true
            proxyActivatedAt = CFAbsoluteTimeGetCurrent()
            print("[READER_PROXY] Activated proxy mode for \(proxyHysteresisDuration)s")
        }
    }

    /// Checks if proxy mode should be deactivated
    func checkProxyDeactivation() {
        if isProxyMode && CFAbsoluteTimeGetCurrent() - proxyActivatedAt > proxyHysteresisDuration {
            isProxyMode = false
            print("[READER_PROXY] Deactivated proxy mode after hysteresis")
        }
    }

    /// Returns true if currently using proxy/mezzanine
    func isUsingProxy() -> Bool {
        return isProxyMode || isIntraframeCodec
    }

    func slide(aroundAbsMs: Int64, trailingHold: Double, label: String = "slide") async {
        if label == "slide", lastSlideTargetMs != .min, llabs(aroundAbsMs - lastSlideTargetMs) < minSlideDeltaMs {
            coalescedSlideCount += 1
            print("[READER_COALESCE] merged=\(coalescedSlideCount + 1) holdMs=\(minSlideDeltaMs)")
            return
        }
        lastSlideTargetMs = aroundAbsMs
        coalescedSlideCount = 0
        let center = seconds(from: aroundAbsMs)
        let clampedTrailing = max(trailingHold, 0.3)
        let start = max(center - clampedTrailing, 0)
        let end = center + clampedTrailing + 0.3
        // Don't preserve IDR for slides - these are small adjustments
        let normalized = normalizeRange(start...end, center: center)

        do {
            try await rebuildReader(range: normalized,
                                    around: center,
                                    raKey: lastRandomAccess?.key,
                                    countsAsRebuild: false)
            metrics.shifts += 1
            metrics.lastShiftTime = CFAbsoluteTimeGetCurrent()
            logSlide(range: normalized, label: label)
        } catch {
            Task { @MainActor in
                print("[SCRUB_READER] slide_failed label=\(label) error=\(error)")
            }
            do {
                try await rebuildReader(range: normalized,
                                        around: center,
                                        raKey: lastRandomAccess?.key,
                                        countsAsRebuild: true)
                metrics.shifts += 1
                metrics.lastShiftTime = CFAbsoluteTimeGetCurrent()
                logSlide(range: normalized, label: label)
            } catch {
                Task { @MainActor in
                    print("[SCRUB_READER] slide_fatal label=\(label) error=\(error)")
                }
            }
        }
    }

    func widenAroundAbsMs(_ centerMs: Int64, trailingHold: Double) async {
        await slide(aroundAbsMs: centerMs, trailingHold: trailingHold, label: "widen")
    }

    func ensureCentered(around tPredMs: Int64) async {
        guard let window = currentWindow else { return }
        let centerSeconds = (window.start + window.end) * 0.5
        let centerMs = Int64((centerSeconds * 1000.0).rounded())
        let delta = llabs(centerMs - tPredMs)
        guard delta > 750 else { return }
        if CFAbsoluteTimeGetCurrent() < recenterFreezeUntil {
            let remaining = max((recenterFreezeUntil - CFAbsoluteTimeGetCurrent()) * 1000.0, 0)
            print("[READER_FREEZE_BLOCK] remaining=\(Int(remaining))ms")
            return
        }

        if let raKey = await analyzer.atOrBefore(absMs: tPredMs, track: track),
           let raTimeMs = await analyzer.timeMs(for: raKey) {
            print("[READER_RECENTER] center=\(centerMs)ms -> \(tPredMs)ms")
            await slide(aroundAbsMs: raTimeMs, trailingHold: trailingHold(), label: "recenter")
            if let raResult = await analyzer.randomAccess(for: raKey) {
                lastRandomAccess = raResult
            }
        } else {
            print("[READER_RECENTER] center=\(centerMs)ms -> \(tPredMs)ms (no RA)")
        }
    }

    // MARK: - Private Methods
    
    /// Rebuilds the reader (only when necessary).
    /// FIX D: Robust error handling with retry logic for kVTVideoDecoderBadDataErr.
    private func rebuildReader(range desiredRange: ClosedRange<TimeInterval>,
                               around tPred: TimeInterval,
                               raKey: RAKey?,
                               retryCount: Int = 0,
                               countsAsRebuild: Bool = true) async throws {
        let start = CFAbsoluteTimeGetCurrent()
        let verboseLogging = await isVerboseLoggingEnabled()

        // Cancel existing reader and flush state
        reader?.cancelReading()
        reader = nil
        output = nil

        var normalizedRange = normalizeRange(desiredRange, center: tPred)
        print("[READER_REBUILD] clip=\(clipID) range=[\(String(format: "%.3f", normalizedRange.lowerBound)),\(String(format: "%.3f", normalizedRange.upperBound))] tPred=\(String(format: "%.3f", tPred)) retry=\(retryCount) preserveIDR=\(shouldPreserveIDRStart())")
        if let raKey {
            print("[READER_REBUILD] usingRA=\(raKey)")
        }

        let now = CFAbsoluteTimeGetCurrent()
        rebuildTimestamps.append(now)
        rebuildTimestamps = rebuildTimestamps.filter { now - $0 < 1.0 }
        if rebuildTimestamps.count > 4 {
            normalizedRange = expandRange(normalizedRange, center: tPred)
            rebuildTimestamps.removeAll()
        }

        // Window calculation is now thread-safe, removed test code

        let windowStart = normalizedRange.lowerBound
        let windowEnd = normalizedRange.upperBound
        let duration = windowEnd - windowStart

        if verboseLogging {
            print("[TIMERANGE_DEBUG] Creating reader with:")
            print("  windowStart=\(String(format: "%.3f", windowStart))")
            print("  windowEnd=\(String(format: "%.3f", windowEnd))")
            print("  duration=\(String(format: "%.3f", duration))")
            print("  assetDuration=\(String(format: "%.3f", assetDuration))")
        }

        // Asset duration validation
        if windowEnd > assetDuration || windowStart < 0 {
            print("[ERROR] Window outside asset bounds! windowStart=\(windowStart), windowEnd=\(windowEnd), assetDuration=\(assetDuration)")
        }
        if !windowStart.isFinite || !windowEnd.isFinite {
            print("[ERROR] Window contains NaN/Inf! windowStart=\(windowStart), windowEnd=\(windowEnd)")
        }

        // Create new reader
        let newReader = try AVAssetReader(asset: asset)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: windowStart, preferredTimescale: 24000),
            duration: CMTime(seconds: duration, preferredTimescale: 24000)
        )

        if verboseLogging {
            print("[TIMERANGE_DEBUG] CMTimeRange:")
            print("  start.seconds=\(String(format: "%.3f", timeRange.start.seconds)) value=\(timeRange.start.value) flags=\(timeRange.start.flags.rawValue)")
            print("  duration.seconds=\(String(format: "%.3f", timeRange.duration.seconds)) value=\(timeRange.duration.value) flags=\(timeRange.duration.flags.rawValue)")
        }

        // CMTimeRange validation
        if !timeRange.isValid || timeRange.isEmpty {
            print("[ERROR] Invalid CMTimeRange created! isValid=\(timeRange.isValid), isEmpty=\(timeRange.isEmpty)")
        }
        if timeRange.duration.seconds < 0 {
            print("[ERROR] Negative duration in CMTimeRange! duration=\(timeRange.duration.seconds)")
        }

        newReader.timeRange = timeRange
        
        // Configure output - Always use AVFoundation decoding for now
        // VT session with compressed samples needs proper callback implementation
        let outputPixelFormat = deriveOutputPixelFormat()
        let outputSettings = makeOutputSettings(pixelFormat: outputPixelFormat)
        let zeroCopyPreferred = await shouldEnableZeroCopy(pixelFormat: outputPixelFormat)

        print("[READER_CONFIG] codec=\(fourCCString(trackMediaSubType)) pixelFormat=\(fourCCString(outputPixelFormat)) zeroCopy=\(zeroCopyPreferred ? "ON" : "OFF") intraframe=\(isIntraframeCodec)")

        let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        newOutput.alwaysCopiesSampleData = !zeroCopyPreferred  // Zero-copy only when safe

        // For H.264/HEVC, ensure we respect sync samples
        if codec == .avc || codec == .hevc {
            newOutput.supportsRandomAccess = true  // Enable random access mode
            print("[READER_CONFIG] Enabled random access mode for \(codec) codec")
        }
        
        guard newReader.canAdd(newOutput) else {
            throw NSError(domain: "PersistentScrubReader", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }
        
        newReader.add(newOutput)
        
        // FIX D: Retry logic for decoder errors
        guard newReader.startReading() else {
            let error = newReader.error
            let errorCode = (error as NSError?)?.code ?? 0
            lastReaderErrorCode = errorCode

            // Check for kVTVideoDecoderBadDataErr
            if errorCode == vtDecoderBadDataCode {
                // Activate proxy mode on VT errors
                activateProxyMode()

                // Also tell VT session to escalate fallback
                if let vtSession = vtSession {
                    Task {
                        await vtSession.activateFreezeGate(duration: 0.15)
                    }
                    print("[READER_VT_FALLBACK] Triggered VT fallback due to error \(vtDecoderBadDataCode)")
                }

                if retryCount < 2 {
                    await MainActor.run {
                        if ScrubFeatureFlags.shared.verboseLogging {
                            print("[SCRUB_READER] kVTVideoDecoderBadDataErr, retry \(retryCount + 1)/2 with proxy")
                        }
                    }

                    // Wait briefly and retry with larger window
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                    let expanded = expandRange(normalizedRange, center: tPred)
                    return try await rebuildReader(range: expanded,
                                                   around: tPred,
                                                   raKey: raKey,
                                                   retryCount: retryCount + 1,
                                                   countsAsRebuild: countsAsRebuild)
                }
            }
            
            throw NSError(domain: "PersistentScrubReader", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start reading: \(error?.localizedDescription ?? "unknown")"])
        }

        reader = newReader
        output = newOutput
        currentWindow = ReaderWindow(raKey: raKey,
                                     start: windowStart,
                                     end: windowEnd)
        activeReaderRange = windowStart...windowEnd
        lastReaderErrorCode = nil

        if countsAsRebuild {
            metrics.rebuilds += 1
            metrics.lastRebuildTime = CFAbsoluteTimeGetCurrent()
        }
        
        let rebuildDuration = (CFAbsoluteTimeGetCurrent() - start) * 1000
        
        // Capture metrics before MainActor
        let currentMetrics = metrics
        
        await MainActor.run {
            // TEMP: Always log for debugging
            ScrubTelemetry.shared.logScrubReader(ScrubTelemetry.ScrubReaderLog(
                timestamp: CFAbsoluteTimeGetCurrent(),
                clipID: clipID,
                windowStart: windowStart,
                windowEnd: windowEnd,
                shifts: currentMetrics.shifts,
                rebuilds: currentMetrics.rebuilds,
                durationMS: rebuildDuration
            ))
            let covers = windowStart <= tPred && windowEnd >= tPred
            ReverseScrubDiagnostics.shared.logReaderRange(clipID: clipID,
                                                          window: windowStart...windowEnd,
                                                          target: tPred,
                                                          covers: covers)
        }
    }

    private func computeWindowRange(tPred: TimeInterval,
                                    randomAccess: GOPAnalyzer.RandomAccessResult?,
                                    targetPTS: TimeInterval,
                                    preroll: ClosedRange<TimeInterval>?) -> ClosedRange<TimeInterval> {
        let safeDuration = assetDuration.isFinite ? assetDuration : Double.greatestFiniteMagnitude
        let clampedPred = max(0.0, min(tPred, safeDuration))
        let safeTarget = max(0.0, min(targetPTS, safeDuration))

        // For H.264/HEVC, ALWAYS start from the IDR frame
        var start: TimeInterval
        if let ra = randomAccess, ra.kind != .none, ra.pts.isFinite {
            // Use a generous preroll before the IDR to cover bi-directional GOPs
            let leadIn = idrLeadInDuration
            start = max(0.0, ra.pts - leadIn)
            let framesBeforeIDR = max(Int(((ra.pts - start) / frameDuration).rounded()), 1)
            print("[READER_WINDOW] Using IDR start: \(String(format: "%.3f", start)) lead=\(String(format: "%.3f", leadIn))s framesBeforeIDR=\(framesBeforeIDR) target=\(String(format: "%.3f", clampedPred))")
        } else {
            // Fallback if no IDR info available
            let raKind = randomAccess?.kind.rawValue ?? "nil"
            let raPTS = randomAccess?.pts
            print("[READER_FALLBACK] No valid IDR: kind=\(raKind) pts=\(raPTS.map { String(format: "%.3f", $0) } ?? "nil") target=\(String(format: "%.3f", clampedPred))")
            let minStart = max(0.0, clampedPred - maxReverseLookback)
            var startCandidates: [TimeInterval] = [max(0.0, clampedPred - config.scrubReaderWindow * 0.6)]
            if let preroll {
                startCandidates.append(max(0.0, min(preroll.lowerBound, preroll.upperBound)))
            }
            if clampedPred < frameDuration * 3.0 {
                startCandidates.append(0.0)
            }
            start = startCandidates.min() ?? minStart
            start = max(start, minStart)
            start = min(start, clampedPred)
        }

        // End calculation remains the same
        let maxEnd = safeDuration.isFinite ? min(safeDuration, clampedPred + maxForwardHead) : clampedPred + maxForwardHead
        var endCandidates: [TimeInterval] = [clampedPred + max(frameDuration * 4.0, 0.12), max(safeTarget, clampedPred) + frameDuration * 2.0]
        if let preroll {
            endCandidates.append(max(preroll.lowerBound, preroll.upperBound))
        }
        if let ra = randomAccess, ra.kind != .none, ra.pts.isFinite, ra.pts > clampedPred {
            endCandidates.append(ra.pts + frameDuration * 2.0)
        }
        if safeTarget > safeDuration - frameDuration * 3.0 {
            endCandidates.append(safeDuration)
        }

        var end = endCandidates.max() ?? maxEnd
        end = min(max(end, clampedPred), maxEnd)

        var rawRange = start...end

        if safeTarget < rawRange.lowerBound || safeTarget > rawRange.upperBound {
            let span = maxReverseLookback + maxForwardHead
            var adjustedStart = max(0.0, safeTarget - maxReverseLookback)
            var adjustedEnd = adjustedStart + span
            if assetDuration.isFinite, adjustedEnd > assetDuration {
                adjustedEnd = assetDuration
                adjustedStart = max(0.0, adjustedEnd - span)
            }
            print("[READER_RANGE_ADJUST] target=\(String(format: "%.3f", safeTarget)) outside window=[\(String(format: "%.3f", rawRange.lowerBound)),\(String(format: "%.3f", rawRange.upperBound))] -> adjusted=[\(String(format: "%.3f", adjustedStart)),\(String(format: "%.3f", adjustedEnd))]")
            rawRange = adjustedStart...adjustedEnd
            return normalizeRange(rawRange, center: safeTarget, preserveIDRStart: false)
        }

        // Preserve IDR start for H.264/HEVC
        let shouldPreserveIDR = (codec == .avc || codec == .hevc) && randomAccess != nil && randomAccess!.kind != .none
        return normalizeRange(rawRange, center: clampedPred, preserveIDRStart: shouldPreserveIDR)
    }

    private func trailingHold() -> Double {
        codec == .hevc ? 0.60 : 0.50
    }

    private func seconds(from absMs: Int64) -> TimeInterval {
        max(Double(absMs) / 1000.0, 0)
    }

    private func logSlide(range: ClosedRange<TimeInterval>, label: String) {
        let startMs = Int((range.lowerBound * 1000.0).rounded())
        let endMs = Int((range.upperBound * 1000.0).rounded())
        let shiftCount = metrics.shifts
        let rebuildCount = metrics.rebuilds
        print("[SCRUB_READER] \(label) start=\(startMs)ms end=\(endMs)ms shifts=\(shiftCount) rebuilds=\(rebuildCount)")
    }

    private func normalizeRange(_ range: ClosedRange<TimeInterval>, center: TimeInterval, preserveIDRStart: Bool = false) -> ClosedRange<TimeInterval> {
        var start = max(range.lowerBound, 0.0)
        var end = max(range.upperBound, start + minimumWindowSpan)

        if assetDuration.isFinite {
            end = min(end, assetDuration)
            // Don't adjust start if we need to preserve IDR alignment
            if !preserveIDRStart {
                start = min(start, max(0.0, end - minimumWindowSpan))
            }
        }

        let maxSpan = maxReverseLookback + maxForwardHead
        if end - start > maxSpan {
            if preserveIDRStart {
                // Keep the IDR-aligned start, adjust end instead
                end = min(start + maxSpan, assetDuration.isFinite ? assetDuration : start + maxSpan)
                print("[READER_NORMALIZE] Preserving IDR start at \(String(format: "%.3f", start)), adjusted end to \(String(format: "%.3f", end))")
            } else {
                // Original logic for non-H.264 content
                let clampedCenter = min(max(center, start), end)
                start = max(clampedCenter - maxReverseLookback, 0.0)
                end = start + maxSpan
                if assetDuration.isFinite {
                    end = min(end, assetDuration)
                    if end - start < maxSpan {
                        start = max(0.0, end - maxSpan)
                    }
                }
            }
        }

        if end - start < minimumWindowSpan {
            end = max(start + minimumWindowSpan, end)
            if assetDuration.isFinite && end > assetDuration {
                end = assetDuration
                // Only adjust start if not preserving IDR
                if !preserveIDRStart {
                    start = max(0.0, end - minimumWindowSpan)
                }
            }
        }

        return start...end
    }

    private func deriveOutputPixelFormat() -> OSType {
        guard isIntraframeCodec else {
            return config.pixelFormat
        }

        switch trackMediaSubType {
        case kCMVideoCodecType_AppleProRes4444:
            // Preserve alpha when possible.
            return kCVPixelFormatType_32BGRA
        case kCMVideoCodecType_AppleProRes422,
             kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy:
            return kCVPixelFormatType_422YpCbCr8
        default:
            return config.pixelFormat
        }
    }

    private func makeOutputSettings(pixelFormat: OSType) -> [String: Any] {
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        settings[kCVPixelBufferCGImageCompatibilityKey as String] = true
        settings[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true
#if os(macOS)
        settings[kCVPixelBufferOpenGLCompatibilityKey as String] = true
#endif
        return settings
    }

    private func shouldEnableZeroCopy(pixelFormat: OSType) async -> Bool {
        // Only attempt zero-copy when using the configured 420 path and non-intraframe codecs.
        guard await isZeroCopyEnabled() else { return false }
        guard !isIntraframeCodec else { return false }
        return pixelFormat == config.pixelFormat
    }

    private func fourCCString(_ value: UInt32) -> String {
        guard value != 0 else { return "----" }

        var scalars: [UnicodeScalar] = []
        var printable = true

        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((value >> UInt32(shift)) & 0xFF)
            if byte == 0 {
                scalars.append(UnicodeScalar(32))
                continue
            }

            if (32...126).contains(byte) {
                scalars.append(UnicodeScalar(byte))
            } else {
                printable = false
                break
            }
        }

        if printable, !scalars.isEmpty {
            return String(String.UnicodeScalarView(scalars))
        }

        return String(format: "0x%08X", value)
    }

    private func isVerboseLoggingEnabled() async -> Bool {
        await MainActor.run { ScrubFeatureFlags.shared.verboseLogging }
    }

    private func isZeroCopyEnabled() async -> Bool {
        await MainActor.run { ScrubFeatureFlags.shared.zeroCopyPath }
    }

    private func expandRange(_ range: ClosedRange<TimeInterval>, center: TimeInterval, preserveIDR: Bool = false) -> ClosedRange<TimeInterval> {
        let span = max(range.upperBound - range.lowerBound, minimumWindowSpan)
        let expansion = max(span * 0.5, frameDuration * 6.0)

        var start = preserveIDR ? range.lowerBound : max(range.lowerBound - expansion * 0.5, 0.0)
        var end = range.upperBound + expansion * 0.5

        if !preserveIDR {
            let minStart = max(0.0, center - maxReverseLookback)
            if start < minStart { start = minStart }
        }

        let maxEnd = assetDuration.isFinite ? min(assetDuration, center + maxForwardHead) : center + maxForwardHead
        if end > maxEnd { end = maxEnd }

        if end <= start {
            end = start + minimumWindowSpan
        }

        return normalizeRange(start...end, center: center, preserveIDRStart: preserveIDR)
    }

    private var minimumWindowSpan: TimeInterval {
        max(frameDuration * 6.0, 0.5)
    }

    private func overlaps(_ window: ReaderWindow, tPred: TimeInterval) -> Bool {
        tPred >= window.start - epsilon && tPred <= window.end + epsilon
    }

    /// Ensures reader exists before attempting to read frame.
    private func ensureReaderReady(for pts: TimeInterval) async throws {
        if reader == nil || output == nil {
            let randomAccess = try await analyzer.findRandomAccess(near: pts, asset: asset, track: track)
            let range = computeWindowRange(tPred: pts,
                                           randomAccess: randomAccess,
                                           targetPTS: pts,
                                           preroll: nil)
            lastWindowIDR = randomAccess.pts
            lastRandomAccess = randomAccess
            try await rebuildReader(range: range,
                                    around: pts,
                                    raKey: randomAccess.key)
        }
    }

    /// Reads frame at target PTS, optionally retrying once after rebuild.
    private func readFrame(at pts: TimeInterval, allowRetry: Bool) async throws -> (CVPixelBuffer, TimeInterval) {
        let verboseLogging = await isVerboseLoggingEnabled()

        let requestedPTS = pts
        let targetPTS = snapPTS(requestedPTS)
        let tolerance = matchTolerance

        var attempts = 0
        var leadingDrops = 0
        var foundKeyframe = false
        var missingOutput = false
        var firstHasFormatDesc = false
        var monotonicDTS = true
        var previousDTS: Double?

        // For H.264/HEVC, log when we encounter sync samples
        while true {
            // Thread-safe sample buffer reading
            readerLock.lock()
            guard let currentOutput = output else {
                readerLock.unlock()
                missingOutput = true
                break
            }
            let sampleBuffer = currentOutput.copyNextSampleBuffer()
            readerLock.unlock()

            guard let sampleBuffer = sampleBuffer else {
                break
            }
            attempts += 1
            if attempts == 1 {
                firstHasFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) != nil
            }
            let decodeTime = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            if decodeTime.isValid {
                let currentDTS = decodeTime.seconds
                if let previous = previousDTS, currentDTS + 1e-4 < previous {
                    monotonicDTS = false
                }
                previousDTS = currentDTS
            }
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

            let readerErrorCode = (reader?.error as NSError?)?.code

            if !CMSampleBufferIsValid(sampleBuffer) {
                consecutiveReadFailures += 1
                print("[READER_SAMPLE_ERR] Invalid sample buffer at pts=\(String(format: "%.3f", samplePTS)) attempts=\(attempts)")
                return try await handleReaderFailure(errorCode: readerErrorCode,
                                                     targetPTS: targetPTS,
                                                     samplePTS: samplePTS,
                                                     context: "invalid-sample",
                                                     allowRetry: allowRetry)
            }

            if !CMSampleBufferDataIsReady(sampleBuffer) {
                consecutiveReadFailures += 1
                print("[READER_SAMPLE_ERR] Data not ready at pts=\(String(format: "%.3f", samplePTS)) attempts=\(attempts)")
                return try await handleReaderFailure(errorCode: readerErrorCode,
                                                     targetPTS: targetPTS,
                                                     samplePTS: samplePTS,
                                                     context: "data-not-ready",
                                                     allowRetry: allowRetry)
            }

            if verboseLogging {
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
                    if mediaType == kCMMediaType_Video {
                        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                        print("[SAMPLE_DEBUG] pts=\(String(format: "%.3f", samplePTS)) mediaType=\(fourCCString(UInt32(mediaType))) subType=\(fourCCString(UInt32(mediaSubType))) size=\(dims.width)x\(dims.height)")
                    } else {
                        print("[SAMPLE_DEBUG] pts=\(String(format: "%.3f", samplePTS)) mediaType=\(fourCCString(UInt32(mediaType))) subType=\(fourCCString(UInt32(mediaSubType)))")
                    }
                } else {
                    print("[SAMPLE_DEBUG] No format description at pts=\(String(format: "%.3f", samplePTS))")
                }
            }

            // Check if this is a sync sample (keyframe)
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let first = attachments.first {
                let isSync = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                if isSync && !foundKeyframe {
                    foundKeyframe = true
                    print("[READER_SYNC] Found sync sample at pts=\(String(format: "%.3f", samplePTS)) while seeking target=\(String(format: "%.3f", targetPTS)) requested=\(String(format: "%.3f", requestedPTS))")
                }
            }
            
            // Format-change detection
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if lastFormatDesc == nil {
                    lastFormatDesc = formatDesc
                } else if !CMFormatDescriptionEqual(lastFormatDesc!, otherFormatDescription: formatDesc) {
                    consecutiveFormatChanges += 1
                    print("[READER_FORMAT_CHANGE] clip=\(clipID) pts=\(String(format: "%.3f", samplePTS)) consecutive=\(consecutiveFormatChanges)")
                    
                    if consecutiveFormatChanges > 2 {
                        print("[READER_FORMAT_UNSTABLE] clip=\(clipID) Too many format changes, rebuilding reader")
                        lastFormatDesc = formatDesc
                        consecutiveFormatChanges = 0

                        if allowRetry {
                            let randomAccess = try await analyzer.findRandomAccess(near: targetPTS, asset: asset, track: track)
                            let range = computeWindowRange(tPred: targetPTS, randomAccess: randomAccess, targetPTS: targetPTS, preroll: nil)
                            lastWindowIDR = randomAccess.pts
                            lastRandomAccess = randomAccess
                            try await rebuildReader(range: range, around: targetPTS, raKey: randomAccess.key)
                            return try await readFrame(at: targetPTS, allowRetry: false)
                        }
                    }
                    
                    lastFormatDesc = formatDesc
                }
            }

            if shouldDropLeadingFrame(sampleBuffer) {
                leadingDrops += 1
                continue
            }

            // Skip non-sync samples if we haven't found a keyframe yet for H.264/HEVC
            if (codec == .avc || codec == .hevc) && !foundKeyframe {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                   let first = attachments.first {
                    let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? false
                    if dependsOnOthers {
                        print("[READER_SKIP] Skipping dependent frame at pts=\(String(format: "%.3f", samplePTS)) - no keyframe found yet")
                        leadingDrops += 1
                        continue
                    }
                }
            }

            // Extract pixel buffer - already decoded by AVFoundation
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                consecutiveReadFailures += 1
                print("[READER_DECODE_ERR] No pixel buffer from AVFoundation at pts=\(String(format: "%.3f", samplePTS)) attempts=\(attempts)")
                return try await handleReaderFailure(errorCode: readerErrorCode,
                                                     targetPTS: targetPTS,
                                                     samplePTS: samplePTS,
                                                     context: "no-pixel-buffer",
                                                     allowRetry: allowRetry)
            }

            if abs(samplePTS - targetPTS) <= tolerance {
                consecutiveReadFailures = 0  // Reset on success
                lastReaderErrorCode = nil
                lastDecodePTS = samplePTS  // Track for direction
                if let windowRange = currentWindow?.range ?? activeReaderRange {
                    let idr = lastWindowIDR
                    let raKind = lastRandomAccess?.kind
                    await MainActor.run {
                        ReverseScrubDiagnostics.shared.logReaderWindow(clipID: clipID,
                                                                      randomAccessPTS: idr,
                                                                      randomAccessKind: raKind.map { $0.rawValue.uppercased() },
                                                                      window: windowRange,
                                                                      decoded: true,
                                                                      attempts: attempts,
                                                                      droppedLeading: leadingDrops,
                                                                      shownPTS: samplePTS,
                                                                      errorCode: nil)
                    }
                }
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logVTOrder(samplesForward: attempts > 0,
                                                              firstHasFormatDesc: firstHasFormatDesc,
                                                              monotonicDTS: monotonicDTS)
                }
                return (pixelBuffer, samplePTS)
            }
        }

        if missingOutput {
            if allowRetry {
                let randomAccess = try await analyzer.findRandomAccess(near: targetPTS, asset: asset, track: track)
                let range = computeWindowRange(tPred: targetPTS,
                                               randomAccess: randomAccess,
                                               targetPTS: targetPTS,
                                               preroll: nil)
                lastWindowIDR = randomAccess.pts
                lastRandomAccess = randomAccess
                try await rebuildReader(range: range,
                                        around: targetPTS,
                                        raKey: randomAccess.key)
                return try await readFrame(at: targetPTS, allowRetry: false)
            }

            throw ScrubReaderError.decodeFailed(code: lastReaderErrorCode)
        }

        if let reader = reader,
           let nsError = reader.error as NSError?,
           nsError.code != 0 {
            let status = reader.status
            print("[READER_ERROR_STATE] clip=\(clipID) status=\(status.rawValue) code=\(nsError.code) context=post-loop attempts=\(attempts)")
            if allowRetry {
                consecutiveReadFailures += 1
                return try await handleReaderFailure(errorCode: nsError.code,
                                                     targetPTS: pts,
                                                     samplePTS: nil,
                                                     context: "post-loop-reader-error",
                                                     allowRetry: allowRetry)
            }
            lastReaderErrorCode = nsError.code
        }

        // Check reader status for diagnostics
        if let reader = reader {
            let status = reader.status
            if status == .failed {
                let nsError = reader.error as NSError?
                let code = nsError?.code
                let message = nsError?.localizedDescription ?? "unknown"
                print("[READER_FAILED] clip=\(clipID) status=failed code=\(code ?? 0) message=\(message)")
                if allowRetry {
                    consecutiveReadFailures += 1
                    return try await handleReaderFailure(errorCode: code,
                                                         targetPTS: targetPTS,
                                                         samplePTS: nil,
                                                         context: "reader-status-failed",
                                                         allowRetry: allowRetry)
                }
                lastReaderErrorCode = code
            } else if status == .cancelled {
                print("[READER_CANCELLED] clip=\(clipID)")
            }
        }
        
        if allowRetry {
            print("[READER_RETRY] clip=\(clipID) pts=\(String(format: "%.3f", targetPTS)) requested=\(String(format: "%.3f", requestedPTS)) Rebuilding reader")
            let randomAccess = try await analyzer.findRandomAccess(near: targetPTS, asset: asset, track: track)
            let baseRange = computeWindowRange(tPred: targetPTS,
                                               randomAccess: randomAccess,
                                               targetPTS: targetPTS,
                                               preroll: nil)
            let expanded = expandRange(baseRange,
                                       center: targetPTS,
                                       preserveIDR: randomAccess.kind != .none)
            lastWindowIDR = randomAccess.pts
            lastRandomAccess = randomAccess
            try await rebuildReader(range: expanded,
                                    around: targetPTS,
                                    raKey: randomAccess.key)
            return try await readFrame(at: targetPTS, allowRetry: false)
        }

        if let windowRange = currentWindow?.range ?? activeReaderRange {
            let idr = lastWindowIDR
            let raKind = lastRandomAccess?.kind
            let errorCode = lastReaderErrorCode
            await MainActor.run {
                ReverseScrubDiagnostics.shared.logReaderWindow(clipID: clipID,
                                                              randomAccessPTS: idr,
                                                              randomAccessKind: raKind.map { $0.rawValue.uppercased() },
                                                              window: windowRange,
                                                              decoded: false,
                                                              attempts: attempts,
                                                              droppedLeading: leadingDrops,
                                                              shownPTS: nil,
                                                              errorCode: errorCode)
            }
        }

        throw ScrubReaderError.decodeFailed(code: lastReaderErrorCode)
    }

    private func shouldPreserveIDRStart() -> Bool {
        guard (codec == .avc || codec == .hevc), let randomAccess = lastRandomAccess else {
            return false
        }
        return randomAccess.kind != .none
    }

    private func handleReaderFailure(errorCode: Int?,
                                     targetPTS: TimeInterval,
                                     samplePTS: TimeInterval?,
                                     context: String,
                                     allowRetry: Bool) async throws -> (CVPixelBuffer, TimeInterval) {
        let code = errorCode ?? lastReaderErrorCode
        lastReaderErrorCode = code

        if let code = code {
            if code == vtDecoderBadDataCode {
                print("[READER_BAD_DATA] clip=\(clipID) context=\(context) target=\(String(format: "%.3f", targetPTS)) sample=\(samplePTS.map { String(format: "%.3f", $0) } ?? "-")")
                activateProxyMode()
                if let vtSession {
                    await vtSession.flushAndReset()
                    await vtSession.activateFreezeGate(duration: 0.18)
                }
            } else {
                print("[READER_FAILURE] clip=\(clipID) code=\(code) context=\(context) target=\(String(format: "%.3f", targetPTS)) sample=\(samplePTS.map { String(format: "%.3f", $0) } ?? "-")")
            }
        } else {
            print("[READER_FAILURE] clip=\(clipID) code=nil context=\(context) target=\(String(format: "%.3f", targetPTS))")
        }

        guard allowRetry else {
            throw ScrubReaderError.decodeFailed(code: code)
        }

        consecutiveReadFailures = 0

        let baseRange = computeWindowRange(tPred: targetPTS,
                                           randomAccess: lastRandomAccess,
                                           targetPTS: targetPTS,
                                           preroll: nil)
        let expanded = expandRange(baseRange,
                                   center: targetPTS,
                                   preserveIDR: shouldPreserveIDRStart())

        try await rebuildReader(range: expanded,
                                around: targetPTS,
                                raKey: lastRandomAccess?.key)

        return try await readFrame(at: targetPTS, allowRetry: false)
    }

    private func snapPTS(_ target: TimeInterval) -> TimeInterval {
        guard frameDuration > 0, target.isFinite else { return target }
        return (target / frameDuration).rounded() * frameDuration
    }

    private var matchTolerance: TimeInterval {
        let minimum: TimeInterval = 0.010
        return max(frameDuration * 0.5, minimum)
    }

    private static func deriveDuration(for asset: AVAsset) -> TimeInterval {
        let duration = asset.duration
        guard duration.isValid && !duration.isIndefinite else { return .infinity }
        return duration.seconds
    }

    private var idrLeadInDuration: TimeInterval {
        let minimumLead = max(frameDuration * 5.0, 0.18)
        return min(maxReverseLookback, minimumLead)
    }

    private func reorderLeadFrameCount() -> Int {
        switch codec {
        case .avc:
            return 6
        case .hevc:
            return 8
        }
    }

    private var maxReverseLookback: TimeInterval {
        let base = max(config.scrubReaderWindow, frameDuration * 24.0)
        return min(base, 1.0)
    }

    private var maxForwardHead: TimeInterval {
        return min(max(frameDuration * 4.0, 0.12), 0.20)
    }

    private func shouldDropLeadingFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let randomAccess = lastRandomAccess, randomAccess.kind != .none else {
            return false
        }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachments = attachmentsArray.first else {
            return false
        }

        func boolValue(_ key: CFString) -> Bool? {
            guard let value = attachments[key] else { return nil }
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            let cfValue = value as CFTypeRef
            if CFGetTypeID(cfValue) == CFBooleanGetTypeID() {
                return CFBooleanGetValue(cfValue as! CFBoolean)
            }
            return nil
        }

        if boolValue(kCMSampleAttachmentKey_NotSync) == true {
            return true
        }
        if boolValue(kCMSampleAttachmentKey_DependsOnOthers) == true {
            return true
        }

        let partialKey: CFString = "PartialSync" as CFString
        if boolValue(partialKey) == true {
            return true
        }

        if randomAccess.kind != .idr {
            let randomAccessKey: CFString = "RandomAccess" as CFString
            if let randomFlag = boolValue(randomAccessKey), randomFlag == false {
                return true
            }
        }

        return false
    }
}
