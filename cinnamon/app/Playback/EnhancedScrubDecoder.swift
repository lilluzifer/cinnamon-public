import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Phase 3.3 & 3.4: Keyframe-seek with minimal preroll + Zero-copy format path.
/// Implements IDR-based seeking with 8-12 frame preroll and direct format decoding.
actor EnhancedScrubDecoder {

    // MARK: - Properties

    enum DecodeFlowError: Error {
        case skippedDeadline
    }

    private let originalAsset: AVAsset
    private let originalTrack: AVAssetTrack
    private let originalDimensions: CMVideoDimensions
    private var activeAsset: AVAsset
    private var activeTrack: AVAssetTrack
    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config
    private let gopAnalyzer: GOPAnalyzer
    private let frameDuration: Double
    private let recommendedPrerollFrames: Int
    private var persistentReader: PersistentScrubReader?
    private var persistentVT: PersistentVTSession?
    private var compressedEngine: CompressedScrubEngine?
    private var compressedEngineTrackID: CMPersistentTrackID = 0
    private let admissionController: AdmissionController
    private let proxyManager: SpotProxyManager
    private let isHEVC: Bool
    private let codec: GOPAnalyzer.Codec
    private var lastRandomAccessKey: RAKey?
    private var lastTriedRA: RAKey?
    private var sameRAHits = 0
    private let baseDeltaGuardMs: Int64 = 500
    private var currentDeltaGuardMs: Int64 = 500
    private var recenterCooldownUntil = Date.distantPast
    private let recenterCooldown: TimeInterval = 0.25
    private var cutEdgeActive = false
    private var cutEdgeWarmupDrops = 0
    private var cutEdgeDropsLogged = 0
    private var lastPresentedPTS: TimeInterval?
    private var failureStreakKey: RAKey?
    private var failureStreakCount = 0
    private var cutEdgePresentGateActive = false
    private var lastProxyEnsure: (time: Date, absMs: Int64)?
    private var avoidOriginalUntil: Date = .distantPast
    private var randomAccessCache: [Int64: GOPAnalyzer.RandomAccessResult] = [:]
    private var randomAccessCacheOrder: [Int64] = []
    private let randomAccessCacheBucketMs: Int64 = 120
    private let randomAccessCacheCapacity = 48
    private var frameDurationMs: Int64 {
        max(Int64((frameDuration * 1000.0).rounded()), 16)
    }

    private func cacheBucket(for time: TimeInterval) -> Int64 {
        let ms = Int64((time * 1000.0).rounded())
        return ms / max(randomAccessCacheBucketMs, 1)
    }

    private func cacheRandomAccess(_ result: GOPAnalyzer.RandomAccessResult, forTarget time: TimeInterval) {
        let bucket = cacheBucket(for: time)
        randomAccessCache[bucket] = result
        randomAccessCacheOrder.removeAll { $0 == bucket }
        randomAccessCacheOrder.append(bucket)
        let overflow = randomAccessCacheOrder.count - randomAccessCacheCapacity
        if overflow > 0 {
            for _ in 0..<overflow {
                if let evicted = randomAccessCacheOrder.first {
                    randomAccessCacheOrder.removeFirst()
                    randomAccessCache.removeValue(forKey: evicted)
                }
            }
        }
    }

    private func rememberRandomAccess(_ result: GOPAnalyzer.RandomAccessResult, targetTime: TimeInterval) {
        cacheRandomAccess(result, forTarget: targetTime)
        cacheRandomAccess(result, forTarget: result.pts)
    }

    private func cachedRandomAccess(near time: TimeInterval) async -> GOPAnalyzer.RandomAccessResult? {
        let centerBucket = cacheBucket(for: time)
        for offset in [-1, 0, 1] {
            let bucket = centerBucket + Int64(offset)
            guard let stored = randomAccessCache[bucket] else { continue }
            if abs(stored.pts - time) > 0.6 {
                continue
            }
            let failures = await gopAnalyzer.failCountForKey(stored.key)
            if failures > 0 {
                randomAccessCache.removeValue(forKey: bucket)
                randomAccessCacheOrder.removeAll { $0 == bucket }
                continue
            }
            randomAccessCacheOrder.removeAll { $0 == bucket }
            randomAccessCacheOrder.append(bucket)
            return stored
        }
        return nil
    }

    private func purgeCachedRandomAccess(for key: RAKey) {
        var bucketsToRemove: [Int64] = []
        for (bucket, stored) in randomAccessCache where stored.key == key {
            bucketsToRemove.append(bucket)
        }
        guard !bucketsToRemove.isEmpty else { return }
        for bucket in bucketsToRemove {
            randomAccessCache.removeValue(forKey: bucket)
            randomAccessCacheOrder.removeAll { $0 == bucket }
        }
    }
    private enum AssetKind: Equatable {
        case original
        case proxy(zoneID: UUID)

        var label: String {
            switch self {
            case .original:
                return "original"
            case .proxy:
                return "proxy"
            }
        }

        var debugLabel: String {
            switch self {
            case .original:
                return "original"
            case .proxy(let zoneID):
                return "proxy(\(zoneID.uuidString.prefix(8)))"
            }
        }
    }
    private var currentAssetKind: AssetKind = .original
    private var currentProxyContext: ProxyContext?
    private var proxyContexts: [UUID: ProxyContext] = [:]
    private var activeProxyZoneID: UUID?
    private var consecutiveProxyDecodeFailures = 0
    private var vanguardPadding: Double = 0.5
    private var crimsonPadding: Double = 0.18
    private var compressedEngineSuppressed = false
    private var deadlineAttemptHistory: Set<String> = []
    
    // MARK: - Initialization
    
    init(asset: AVAsset, track: AVAssetTrack, clipID: UUID, config: ScrubFeatureFlags.Config, gopAnalyzer: GOPAnalyzer, admissionController: AdmissionController, proxyManager: SpotProxyManager) {
        self.originalAsset = asset
        self.originalTrack = track
        self.activeAsset = asset
        self.activeTrack = track
        self.clipID = clipID
        self.config = config
        self.gopAnalyzer = gopAnalyzer
        self.admissionController = admissionController
        self.proxyManager = proxyManager
        self.frameDuration = EnhancedScrubDecoder.deriveFrameDuration(from: track)
        self.recommendedPrerollFrames = EnhancedScrubDecoder.deriveRecommendedPrerollFrames(for: track)
        if let formatDescriptions = track.formatDescriptions as? [CMFormatDescription],
           let formatDescription = formatDescriptions.first {
            self.originalDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            self.isHEVC = CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC
            // Initialize VT session with format description
            self.persistentVT = PersistentVTSession(formatDescription: formatDescription, clipID: clipID, config: config)
        } else {
            let transformed = track.naturalSize.applying(track.preferredTransform)
            self.originalDimensions = CMVideoDimensions(width: Int32(abs(transformed.width)),
                                                        height: Int32(abs(transformed.height)))
            self.isHEVC = false
        }
        self.codec = self.isHEVC ? .hevc : .avc
    }
    
    // MARK: - Public Methods
    
    /// Decodes frame at target time with minimal preroll from IDR.
    /// Returns decoded pixel buffer and actual PTS.
    func decodeFrame(at targetTime: TimeInterval,
                     tPred: TimeInterval,
                     direction: ScrubCoordinator.ScrubDirection,
                     deadlineMode: Bool = false) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval, stages: DecodeStages) {
        // CRITICAL: Validate input times to prevent decoder errors
        guard targetTime >= 0 && tPred >= 0 && targetTime < 10000 && tPred < 10000 else {
            await MainActor.run {
                print("❌ [EnhancedScrubDecoder] Invalid times: target=\(targetTime), pred=\(tPred)")
            }
            throw NSError(domain: "EnhancedScrubDecoder", code: -10,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid time values: target=\(targetTime), pred=\(tPred)"])
        }
        
        var stages = DecodeStages()

        // Stage 1: Init (ensure persistent resources)
        let initStart = CFAbsoluteTimeGetCurrent()
        try await ensurePersistentResources()
        stages.initMS = (CFAbsoluteTimeGetCurrent() - initStart) * 1000

        // Stage 2: Seek to RA (with cache)
        var randomAccess: GOPAnalyzer.RandomAccessResult
        var seekDurationMs: Double = 0
        if let cached = await cachedRandomAccess(near: targetTime) {
            randomAccess = cached
            cacheRandomAccess(cached, forTarget: targetTime)
        } else {
            let seekStart = CFAbsoluteTimeGetCurrent()
            randomAccess = try await gopAnalyzer.findRandomAccess(near: targetTime,
                                                                  asset: activeAsset,
                                                                  track: activeTrack)
            seekDurationMs = (CFAbsoluteTimeGetCurrent() - seekStart) * 1000
            rememberRandomAccess(randomAccess, targetTime: targetTime)
        }
        stages.seekIDRMS = seekDurationMs

        let targetAbsMs = ms(from: targetTime)
        let tPredMs = ms(from: tPred)

        logDecodeContext(action: "begin", ra: randomAccess, targetAbsMs: targetAbsMs)

        let minimalPrerollEnabled = await MainActor.run { ScrubFeatureFlags.shared.minimalPreroll }
        var currentPrerollFrames = minimalPrerollEnabled ? max(config.prerollFrames, recommendedPrerollFrames) : 0
        var prerollWindow = minimalPrerollEnabled ? calculatePrerollWindow(idrPTS: randomAccess.pts,
                                                                           targetPTS: targetTime,
                                                                           prerollFrames: currentPrerollFrames) : nil

        await MainActor.run {
            ReverseScrubDiagnostics.shared.logRandomAccessSelection(clipID: self.clipID,
                                                                    targetPTS: targetTime,
                                                                    result: randomAccess,
                                                                    prerollFrames: currentPrerollFrames)
        }

        var workStages = stages
        var decodeResult: (CVPixelBuffer, TimeInterval)?
        let stableReverse = ScrubFeatureFlags.stableReverseScrub
        var quarantinedKeys = Set<RAKey>()
        var attemptCount = 0
        let maxAttempts = 12
        var lastFailure: Error?

        var consecutiveBadData = 0
        var badDataAttempts = 0
        var badDataLeadBoost = 0
        var forwardFeedWindow: ClosedRange<TimeInterval>?
        var forwardFeedMetadata: (anchor: TimeInterval, kind: String, lead: Int)?
        let forwardFeedActive = await MainActor.run {
            ScrubFeatureFlags.stableReverseScrub && direction == .reverse && ScrubFeatureFlags.shared.isReverseForwardFeedEnabled(for: codec) && randomAccess.kind != .none
        }
        let badDataRetryEnabled = await MainActor.run { ScrubFeatureFlags.shared.isBadDataRetryEnabled() }
        let maxBadDataAttempts = await MainActor.run { ScrubFeatureFlags.shared.config.decoderBadDataMaxAttempts }
        var attemptHashes = Set<String>()

        func fetchPrevRandomAccess(before absMs: Int64) async -> GOPAnalyzer.RandomAccessResult? {
            guard absMs > 0 else { return nil }
            guard let key = await gopAnalyzer.prevSyncBefore(absMs: absMs, track: activeTrack),
                  let access = await gopAnalyzer.randomAccess(for: key) else {
                return nil
            }
            return access
        }

        func fetchNextRandomAccess(after absMs: Int64) async -> GOPAnalyzer.RandomAccessResult? {
            guard let nextAbs = await gopAnalyzer.nextSyncAbsMs(after: absMs, track: activeTrack) else {
                return nil
            }
            if let key = await gopAnalyzer.atOrBefore(absMs: nextAbs, track: activeTrack),
               let access = await gopAnalyzer.randomAccess(for: key),
               let recordedAbs = await gopAnalyzer.timeMs(for: key),
               recordedAbs == nextAbs {
                return access
            }
            return nil
        }

        let compressedEngineEnabled = await MainActor.run { ScrubFeatureFlags.shared.compressedScrubEngine }
        if compressedEngineEnabled && direction == .reverse {
            let idrDelta = abs(randomAccess.pts - targetTime)
            let idrGate = config.compressedIdrTargetGate
            let gateAllows = idrGate <= 0 || idrDelta <= idrGate
            if gateAllows {
                let vtSupportsAsync = await persistentVT?.supportsAsyncDecode() ?? false
                if !vtSupportsAsync {
                    if !compressedEngineSuppressed {
                        print("[COMPRESSED_ENGINE] Disabled (no VT output callback); falling back to reader path")
                        compressedEngineSuppressed = true
                    }
                } else {
                    compressedEngineSuppressed = false

                    if compressedEngine == nil || compressedEngineTrackID != activeTrack.trackID {
                        compressedEngine = CompressedScrubEngine(asset: activeAsset,
                                                                 track: activeTrack,
                                                                 clipID: clipID,
                                                                 config: config,
                                                                 gopAnalyzer: gopAnalyzer)
                        compressedEngineTrackID = activeTrack.trackID
                    }

                    guard let vtSession = persistentVT else {
                        throw NSError(domain: "EnhancedScrubDecoder", code: -20,
                                      userInfo: [NSLocalizedDescriptionKey: "VT session unavailable for compressed engine"])
                    }

                    do {
                        let decodeStart = CFAbsoluteTimeGetCurrent()
                        let (pixelBuffer, pts) = try await compressedEngine!.decodeFrame(randomAccess: randomAccess,
                                                                                         targetPTS: targetTime,
                                                                                         direction: direction,
                                                                                         vtSession: vtSession,
                                                                                         requireCache: true,
                                                                                         maxDistance: 0.5)
                        workStages.decodeMS = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                        workStages.firstSampleMS = 0
                        workStages.convertMS = 0
                        workStages.cacheWriteMS = 0
                        decodeResult = (pixelBuffer, pts)
                        lastPresentedPTS = pts
                        await gopAnalyzer.resetFail(for: randomAccess.key)
                        onDecodeSuccess()
                        await MainActor.run {
                            ReverseScrubDiagnostics.shared.logDecoderPath(clipID: self.clipID,
                                                                          decoder: "VT(comp)",
                                                                          pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                                                                          pts: pts)
                            ScrubTelemetry.shared.logDecodeStages(ScrubTelemetry.DecodeStagesLog(
                                timestamp: CFAbsoluteTimeGetCurrent(),
                                pts: pts,
                                initMS: workStages.initMS,
                                seekIDRMS: workStages.seekIDRMS,
                                prerollMS: workStages.prerollMS,
                                firstSampleMS: workStages.firstSampleMS,
                                decodeMS: workStages.decodeMS,
                                convertMS: workStages.convertMS,
                                cacheWriteMS: workStages.cacheWriteMS
                            ))
                        }
                        return (pixelBuffer, pts, workStages)
                    } catch CompressedScrubEngine.EngineError.cacheMiss {
                        // Fall back to reader pipeline on cache miss
                    }
                }
            } else {
                let verbose = await MainActor.run { ScrubFeatureFlags.shared.verboseLogging }
                if verbose {
                    let formattedDelta = String(format: "%.3f", idrDelta)
                    let formattedGate = String(format: "%.3f", idrGate)
                    print("[COMPRESSED_ENGINE] Skip (idr_delta=\(formattedDelta)s > gate=\(formattedGate)s)")
                }
            }
        } else {
            compressedEngineSuppressed = false
        }

        retryLoop: while decodeResult == nil && attemptCount < maxAttempts {
            attemptCount += 1

            if persistentReader == nil {
                try await ensurePersistentResources()
            }
            guard let reader = persistentReader else {
                throw NSError(domain: "EnhancedScrubDecoder", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "No persistent reader"])
            }

            if failureStreakKey != randomAccess.key {
                failureStreakKey = randomAccess.key
                failureStreakCount = 0
            }

            let anchorMs = Int64((randomAccess.pts * 1000.0).rounded())
            let targetMs = Int64((targetTime * 1000.0).rounded())
            let vtSignature = await persistentVT?.formatSignature()
            let readerSignature = await reader.formatSignature()
            let formatSignature = vtSignature ?? readerSignature
            let attemptHash = "\(anchorMs)|\(targetMs)|\(formatSignature)"
            let isDuplicate = !attemptHashes.insert(attemptHash).inserted
            let attemptNumber = attemptCount
            await MainActor.run {
                ScrubTelemetry.shared.logDecodeAttempt(ScrubTelemetry.DecodeAttemptLog(
                    timestamp: CFAbsoluteTimeGetCurrent(),
                    clipID: self.clipID,
                    attempt: attemptNumber,
                    hash: attemptHash,
                    duplicate: isDuplicate
                ))
            }
            if deadlineMode {
                if !deadlineAttemptHistory.insert(attemptHash).inserted {
                    throw DecodeFlowError.skippedDeadline
                }
            }
            if isDuplicate && badDataRetryEnabled {
                badDataLeadBoost += 2
                forwardFeedWindow = nil
                forwardFeedMetadata = nil
                continue retryLoop
            }

            let currentAttemptNumber = attemptNumber

            let cutEdgeNow = await shouldApplyCutEdgePolicy(targetAbsMs: targetAbsMs,
                                                             tPredMs: tPredMs,
                                                             randomAccess: randomAccess)
            updateCutEdgeState(isActive: cutEdgeNow, ra: randomAccess.key, targetAbsMs: targetAbsMs)
            if cutEdgeActive {
                currentDeltaGuardMs = min(currentDeltaGuardMs, frameDurationMs)
                currentPrerollFrames = max(currentPrerollFrames, 3)
            }

            if stableReverse {
                print("[RA_KEY] \(randomAccess.key)")
            }
            lastRandomAccessKey = randomAccess.key

        forwardFeedWindow = nil
        forwardFeedMetadata = nil
        let manualRange: ClosedRange<TimeInterval>? = {
            guard stableReverse else { return nil }
            if forwardFeedActive && randomAccess.kind != .none {
                let frameDurationSafe = max(frameDuration, 1.0 / 120.0)
                let anchorPTS = randomAccess.pts.isFinite ? max(randomAccess.pts, 0) : max(targetTime, 0)
                let backwardFrames = max(currentPrerollFrames, config.prerollFrames)
                let backwardSpan = Double(max(backwardFrames, 1)) * frameDurationSafe
                let start = max(anchorPTS - backwardSpan, 0)
                let leadFrames = max(queryReorderLeadFrames() + badDataLeadBoost, 1)
                var end = max(targetTime + Double(leadFrames) * frameDurationSafe, start + frameDurationSafe)
                if end < targetTime {
                    end = targetTime + frameDurationSafe
                }
                forwardFeedWindow = start...end
                forwardFeedMetadata = (anchorPTS, randomAccess.kind.rawValue.uppercased(), leadFrames)
                return forwardFeedWindow
            }

            let backwardPad = max(vanguardPadding, isHEVC ? 0.75 : 0.50)
            let forwardPad = max(crimsonPadding, 0.18)
            let raPTS = randomAccess.pts.isFinite ? randomAccess.pts : max(targetTime, 0)
            let clampedTarget = targetTime.isFinite ? max(targetTime, 0) : raPTS
            let start = max(raPTS - backwardPad, 0)
            let endCandidate = max(clampedTarget + forwardPad, start + 0.5)
            let end = max(endCandidate, start + 0.1)
            if start.isFinite && end.isFinite && start <= end {
                return start...end
            }
            let fallback = max(clampedTarget - backwardPad, 0)
            let upper = max(fallback + 0.1, fallback)
            return fallback...upper
        }()

        if let window = forwardFeedWindow, let meta = forwardFeedMetadata {
            let covers = window.contains(targetTime)
            await MainActor.run {
                ReverseScrubDiagnostics.shared.logRAMetadata(clipID: self.clipID,
                                                             anchor: meta.anchor,
                                                             kind: meta.kind,
                                                             leadFrames: meta.lead,
                                                             window: window,
                                                             coversTarget: covers)
            }
        }

            let ensureStart = CFAbsoluteTimeGetCurrent()
            try await reader.ensureWindow(around: tPred,
                                          randomAccess: randomAccess,
                                          targetPTS: targetTime,
                                          preroll: prerollWindow,
                                          manualRange: manualRange)
            workStages.firstSampleMS = (CFAbsoluteTimeGetCurrent() - ensureStart) * 1000

            if let window = forwardFeedWindow {
                let covers = window.contains(targetTime)
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logReaderRange(clipID: self.clipID,
                                                                  window: window,
                                                                  target: targetTime,
                                                                  covers: covers)
                }
            }

            do {
                let decodeStart = CFAbsoluteTimeGetCurrent()
                let (pixelBuffer, pts) = try await reader.copyFrame(at: targetTime)
                workStages.decodeMS = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                await gopAnalyzer.resetFail(for: randomAccess.key)
                consecutiveBadData = 0
                onDecodeSuccess()
                if cutEdgeActive && shouldDropFrameForCutEdge(pts: pts, targetAbsMs: targetAbsMs, ra: randomAccess) {
                    continue retryLoop
                }
                lastPresentedPTS = pts
                badDataAttempts = 0
                badDataLeadBoost = 0
                decodeResult = (pixelBuffer, pts)
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logDecoderPath(clipID: self.clipID,
                                                                  decoder: "VT(yuv)",
                                                                  pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                                                                  pts: pts)
                }
            } catch let error as ScrubReaderError {
                lastFailure = error
                let status = OSStatus(error.code ?? Int(kVTVideoDecoderBadDataErr))
                let failingRA = randomAccess.key
                if failureStreakKey == failingRA {
                    failureStreakCount += 1
                } else {
                    failureStreakKey = failingRA
                    failureStreakCount = 1
                }

                if status == kVTVideoDecoderBadDataErr {
                    consecutiveBadData += 1
                    var handledByRetry = false
                    if badDataRetryEnabled {
                        badDataAttempts += 1
                        let leadFrames = max(queryReorderLeadFrames() + badDataLeadBoost, 1)
                        let anchorPTS = randomAccess.pts
                        let nextAction = badDataAttempts == 1 ? "prevSync" : "nextSync"
                        let epsilonMs = max(frameDurationMs, Int64(16))
                        let searchMs = badDataAttempts == 1 ? max(targetAbsMs - epsilonMs, 0) : targetAbsMs + epsilonMs
                        let newAccess = badDataAttempts == 1 ? await fetchPrevRandomAccess(before: searchMs) : await fetchNextRandomAccess(after: searchMs)
                        await MainActor.run {
                            ScrubTelemetry.shared.logDecodeFailure(ScrubTelemetry.DecodeFailureLog(
                                timestamp: CFAbsoluteTimeGetCurrent(),
                                clipID: self.clipID,
                                status: "badData",
                                attempt: currentAttemptNumber,
                                anchor: anchorPTS,
                                leadFrames: leadFrames,
                                nextAction: nextAction
                            ))
                        }
                        if badDataAttempts <= maxBadDataAttempts, let resolvedAccess = newAccess {
                            randomAccess = resolvedAccess
                            rememberRandomAccess(resolvedAccess, targetTime: targetTime)
                            badDataLeadBoost += 2
                            attemptHashes.removeAll()
                            forwardFeedWindow = nil
                            forwardFeedMetadata = nil
                            if minimalPrerollEnabled {
                                currentPrerollFrames = max(currentPrerollFrames + 1, config.prerollFrames)
                                prerollWindow = calculatePrerollWindow(idrPTS: randomAccess.pts,
                                                                       targetPTS: targetTime,
                                                                       prerollFrames: currentPrerollFrames)
                            }
                            if let vt = persistentVT {
                                await vt.invalidate()
                            }
                            if let reader = persistentReader {
                                await reader.invalidate()
                            }
                            try await ensurePersistentResources()
                            handledByRetry = true
                            continue retryLoop
                        }
                    }

                    if !handledByRetry && stableReverse {
                        let boost = Double(min(consecutiveBadData, 6)) * 0.05
                        vanguardPadding = max(vanguardPadding + boost, 0.25)
                        crimsonPadding = max(crimsonPadding + boost * 0.5, 0.18)
                        let guardMultiplier = Double(min(consecutiveBadData + 1, 6))
                        let boostedGuard = Int64(Double(frameDurationMs) * guardMultiplier)
                        currentDeltaGuardMs = max(currentDeltaGuardMs, boostedGuard)
                        let shouldRetry = await handleDecodeFailure(status: status,
                                                                    context: "sync",
                                                                    randomAccess: &randomAccess,
                                                                    currentPrerollFrames: &currentPrerollFrames,
                                                                    minimalPrerollEnabled: minimalPrerollEnabled,
                                                                    targetTime: targetTime,
                                                                    tPred: tPred,
                                                                    reader: reader,
                                                                    quarantined: &quarantinedKeys,
                                                                    cutEdge: cutEdgeActive,
                                                                    targetAbsMs: targetAbsMs,
                                                                    consecutiveBadData: consecutiveBadData)
                        if shouldRetry {
                            if minimalPrerollEnabled {
                                prerollWindow = calculatePrerollWindow(idrPTS: randomAccess.pts,
                                                                       targetPTS: targetTime,
                                                                       prerollFrames: currentPrerollFrames)
                            }
                            attemptHashes.removeAll()
                            let escalate = cutEdgeActive ? failureStreakCount >= 1 : failureStreakCount >= 2
                            if escalate {
                                let raMs = await gopAnalyzer.timeMs(for: failingRA)
                                let context = cutEdgeActive ? "cut-edge" : "decoder"
                                await proxyManager.ensureSpotProxy(clipID: clipID,
                                                                    asset: originalAsset,
                                                                    aroundAbsMs: targetAbsMs,
                                                                    spanMs: 4000,
                                                                    reason: cutEdgeActive ? "cut-edge-retries" : "decoder-retries",
                                                                    context: context,
                                                                    raAnchorMs: raMs)
                                let resetReason = cutEdgeActive ? "cut-edge-retries" : "decoder-retries"
                                await resetDecoderSession(reason: resetReason, ra: failingRA)
                            }
                            if randomAccess.key != failingRA {
                                failureStreakKey = randomAccess.key
                                failureStreakCount = 0
                            }
                            continue retryLoop
                        }
                    }
                } else {
                    consecutiveBadData = 0
                    badDataAttempts = 0
                    badDataLeadBoost = 0
                }

                logDecodeFailure(status: status, ra: failingRA, targetAbsMs: targetAbsMs)
                throw NSError(domain: "EnhancedScrubDecoder", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to decode frame (code: \(status))"])
            } catch is CancellationError {
                lastFailure = CancellationError()
                throw CancellationError()
            } catch {
                lastFailure = error
                throw error
            }
        }

        if decodeResult == nil {
            logDecodeFailure(status: OSStatus(kVTVideoDecoderBadDataErr), ra: randomAccess.key, targetAbsMs: targetAbsMs)
            throw lastFailure ?? NSError(domain: "EnhancedScrubDecoder", code: -2,
                                         userInfo: [NSLocalizedDescriptionKey: "Failed to decode frame"])
        }

        guard let (pixelBuffer, pts) = decodeResult else {
            throw NSError(domain: "EnhancedScrubDecoder", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to decode frame"])
        }

        workStages.convertMS = 0.0
        workStages.cacheWriteMS = 0.0

        await MainActor.run {
            // TEMP: Always log for debugging
            ScrubTelemetry.shared.logDecodeStages(ScrubTelemetry.DecodeStagesLog(
                timestamp: CFAbsoluteTimeGetCurrent(),
                pts: pts,
                initMS: workStages.initMS,
                seekIDRMS: workStages.seekIDRMS,
                prerollMS: workStages.prerollMS,
                firstSampleMS: workStages.firstSampleMS,
                decodeMS: workStages.decodeMS,
                convertMS: workStages.convertMS,
                cacheWriteMS: workStages.cacheWriteMS
            ))
            if ScrubFeatureFlags.shared.telemetryEnabled {
                let deltaMS = (pts - targetTime) * 1000.0
                let predDeltaMS = (pts - tPred) * 1000.0
                let formattedTarget = String(format: "%.3f", targetTime)
                let formattedActual = String(format: "%.3f", pts)
                let formattedTPred = String(format: "%.3f", tPred)
                let formattedDelta = String(format: "%.1f", deltaMS)
                let formattedPredDelta = String(format: "%.1f", predDeltaMS)
                print("[DECODE_DELTA] clip=\(self.clipID.uuidString.prefix(8)) target=\(formattedTarget) tPred=\(formattedTPred) actual=\(formattedActual) Δtarget_ms=\(formattedDelta) Δpred_ms=\(formattedPredDelta) attempts=\(attemptCount) deadline=\(deadlineMode ? "t" : "f") direction=\(direction)")
            }
        }

        return (pixelBuffer, pts, workStages)
    }
    
    /// Invalidates persistent resources.
    func invalidate() async {
        await persistentReader?.invalidate()
        await persistentVT?.invalidate()
        persistentReader = nil
        persistentVT = nil
        await compressedEngine?.invalidate()
        compressedEngine = nil
        compressedEngineTrackID = 0
        deadlineAttemptHistory.removeAll()
    }

    func prepareForDeadline(at targetTime: TimeInterval) async {
        print("[DEADLINE_LOCK] clip=\(clipID) acquired=true")
        let targetAbsMs = ms(from: targetTime)
        do {
            try await ensurePersistentResources()
        } catch {
            print("[DEADLINE_LOCK] clip=\(clipID.uuidString.prefix(8)) ensureResourcesFailed=\(error)")
        }
        if let reader = persistentReader {
            await reader.ensureCentered(around: targetAbsMs)
            await reader.freezeRecentering(for: 0.2, reason: "deadline-lock")
        }
    }
    
    // MARK: - Private Methods
    
    /// Ensures persistent reader and VT session exist.
    private func ensurePersistentResources() async throws {
        // Create persistent VT session FIRST (if needed)
        if persistentVT == nil {
            if let formatDescriptions = activeTrack.formatDescriptions as? [CMFormatDescription],
               let formatDescription = formatDescriptions.first {
                persistentVT = PersistentVTSession(
                    formatDescription: formatDescription,
                    clipID: clipID,
                    config: config
                )
                print("[DECODER_VT] Created VT session for clip \(clipID)")
            }
        }

        // Create persistent reader if needed (AFTER VT session)
        if persistentReader == nil {
            persistentReader = PersistentScrubReader(
                asset: activeAsset,
                track: activeTrack,
                clipID: clipID,
                frameDuration: frameDuration,
                config: config,
                codec: codec,
                analyzer: gopAnalyzer
            )
            // Connect VT session to reader IMMEDIATELY
            if let vtSession = persistentVT {
                await persistentReader?.setVTSession(vtSession)
                print("[DECODER_VT] Connected VT session to reader")
            }
        }

        // Ensure VT session is connected even if both already exist
        if persistentReader != nil && persistentVT != nil {
            await persistentReader?.setVTSession(persistentVT)
        }

        if await MainActor.run(body: { ScrubFeatureFlags.shared.compressedScrubEngine }) {
            if compressedEngine == nil || compressedEngineTrackID != activeTrack.trackID {
                compressedEngine = CompressedScrubEngine(asset: activeAsset,
                                                         track: activeTrack,
                                                         clipID: clipID,
                                                         config: config,
                                                         gopAnalyzer: gopAnalyzer)
                compressedEngineTrackID = activeTrack.trackID
            }
        }
    }
    
    /// Calculates minimal preroll window from IDR to target.
    private func calculatePrerollWindow(idrPTS: TimeInterval,
                                        targetPTS: TimeInterval,
                                        prerollFrames: Int) -> ClosedRange<TimeInterval> {
        guard idrPTS.isFinite else {
            let localFrameDuration = max(frameDuration, 1.0 / 60.0)
            let span = localFrameDuration * Double(max(prerollFrames, 1))
            let upper = targetPTS + max(span, localFrameDuration)
            return max(targetPTS - span, 0)...upper
        }

        let localFrameDuration = max(frameDuration, 1.0 / 60.0)
        let frameCount = max(prerollFrames, 1)
        let prerollDuration = Double(frameCount) * localFrameDuration

        // Window: [IDR ... IDR + prerollDuration]
        // Clamp upper bound close to the target to avoid runaway windows.
        var windowStart = idrPTS
        var windowEnd = idrPTS + prerollDuration

        let targetClampUpper = targetPTS + localFrameDuration * 1.5
        if windowEnd.isFinite {
            windowEnd = min(windowEnd, targetClampUpper)
        } else {
            windowEnd = targetClampUpper
        }

        // Ensure the window covers the target even if the IDR lies ahead.
        if windowEnd < targetPTS {
            windowEnd = targetClampUpper
        }
        if windowStart > windowEnd {
            let lower = min(windowStart, windowEnd)
            let upper = max(windowStart, windowEnd)
            windowStart = lower
            windowEnd = upper
        }

        // Guarantee a minimal span so that downstream range math stays safe.
        if windowEnd - windowStart < localFrameDuration * 0.5 {
            windowEnd = windowStart + localFrameDuration * 0.5
        }

        return windowStart...windowEnd
    }

    private func queryReorderLeadFrames() -> Int {
        switch codec {
        case .avc:
            return 6
        case .hevc:
            return 8
        }
    }

    private func handleDecodeFailure(status: OSStatus,
                                     context: String,
                                     randomAccess: inout GOPAnalyzer.RandomAccessResult,
                                     currentPrerollFrames: inout Int,
                                     minimalPrerollEnabled: Bool,
                                     targetTime: TimeInterval,
                                     tPred: TimeInterval,
                                     reader: PersistentScrubReader,
                                     quarantined: inout Set<RAKey>,
                                     cutEdge: Bool,
                                     targetAbsMs: Int64,
                                     consecutiveBadData: Int) async -> Bool {
        guard ScrubFeatureFlags.stableReverseScrub else { return false }

        let key = randomAccess.key
        print("[DEC_FAIL] status=\(status) ctx=\(context) key=\(key)")

        quarantined.insert(key)
        await gopAnalyzer.noteFail(key)
        purgeCachedRandomAccess(for: key)

        let failureCount = failureStreakCount
        let isBadData = isBadDataStatus(status)

        if isBadData {
            await proxyManager.debugLogStatus(clipID: clipID, label: "decoder-fail")
            await ensureProxyCoverageIfNeeded(targetAbsMs: targetAbsMs,
                                              cutEdge: cutEdge,
                                              reason: cutEdge ? "cut-edge-recover" : "decoder-bad-data")

            let targetSeconds = Double(targetAbsMs) / 1000.0
            if let freshResult = try? await gopAnalyzer.findRandomAccess(near: targetSeconds,
                                                                          asset: activeAsset,
                                                                          track: activeTrack),
               freshResult.key != key,
               let freshAbs = await gopAnalyzer.timeMs(for: freshResult.key) {
                let candidate = FallbackCandidate(key: freshResult.key,
                                                  absMs: freshAbs,
                                                  access: freshResult)
                await adoptFallback(candidate: candidate,
                                    targetAbsMs: targetAbsMs,
                                    randomAccess: &randomAccess,
                                    currentPrerollFrames: &currentPrerollFrames,
                                    minimalPrerollEnabled: minimalPrerollEnabled,
                                    reader: reader,
                                    label: "bad_data_fresh")
                await persistentVT?.flushAndReset()
                return true
            }
        }

        if isBadData {
            let quarantineDeadline = CFAbsoluteTimeGetCurrent() + (cutEdge ? 0.8 : 0.5)
            await gopAnalyzer.quarantine(key, until: quarantineDeadline)

            if failureCount == 1,
               !cutEdge {
                if minimalPrerollEnabled {
                    let boost = codec == .hevc ? 2 : 1
                    let minimum = max(recommendedPrerollFrames, codec == .hevc ? 5 : 3)
                    currentPrerollFrames = max(currentPrerollFrames + boost, minimum)
                }
                await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
                await reader.freezeRecentering(for: 0.12, reason: "bad-data-first")
                await persistentVT?.flushAndReset()
                return true
            }
        }

        if isBadData,
           failureCount >= 2,
           currentAssetKind == .original {
            if await backoffAfterDoubleFailure(failingKey: key,
                                               targetAbsMs: targetAbsMs,
                                               randomAccess: &randomAccess,
                                               currentPrerollFrames: &currentPrerollFrames,
                                               minimalPrerollEnabled: minimalPrerollEnabled,
                                               reader: reader,
                                               quarantined: &quarantined) {
                return true
            }
        }

        if isBadData, case .proxy = currentAssetKind {
            consecutiveProxyDecodeFailures += 1
            if consecutiveProxyDecodeFailures >= 2 {
                print("[PROXY_FALLBACK] clip=\(clipID.uuidString.prefix(8)) status=bad_data switching=original")
                if let zoneID = activeProxyZoneID {
                    await proxyManager.markPlaybackFailure(clipID: clipID,
                                                            zoneID: zoneID,
                                                            reason: "bad-data")
                }
                await useOriginalSource()
                quarantined.removeAll()
                var appliedFallback = false
                if let altKey = await gopAnalyzer.prevSyncBefore(absMs: max(targetAbsMs - frameDurationMs * 2, 0), track: activeTrack),
                   let altAbs = await gopAnalyzer.timeMs(for: altKey),
                   let altAccess = await gopAnalyzer.randomAccess(for: altKey) {
                    let candidate = FallbackCandidate(key: altKey, absMs: altAbs, access: altAccess)
                    await adoptFallback(candidate: candidate,
                                        targetAbsMs: targetAbsMs,
                                        randomAccess: &randomAccess,
                                        currentPrerollFrames: &currentPrerollFrames,
                                        minimalPrerollEnabled: minimalPrerollEnabled,
                                        reader: nil,
                                        label: "proxy-recover")
                    appliedFallback = true
                }

                if !appliedFallback {
                    do {
                       let refreshed = try await gopAnalyzer.findRandomAccess(near: targetTime,
                                                                             asset: activeAsset,
                                                                             track: activeTrack)
                       randomAccess = refreshed
                        rememberRandomAccess(refreshed, targetTime: targetTime)
                        lastRandomAccessKey = refreshed.key
                        sameRAHits = 0
                        failureStreakKey = refreshed.key
                        failureStreakCount = 0
                        if minimalPrerollEnabled {
                            let fallbackPreroll = codec == .hevc ? 6 : 4
                            currentPrerollFrames = max(currentPrerollFrames, fallbackPreroll)
                        }
                    } catch {
                        print("[PROXY_FALLBACK_FAIL] clip=\(clipID.uuidString.prefix(8)) findRA=\(error)")
                    }
                }

                consecutiveProxyDecodeFailures = 0
                return true
            }
        } else {
            consecutiveProxyDecodeFailures = 0
        }

        let tPredMs = ms(from: tPred)
        await logAnalyzerRange()
        updateDeltaGuardAfterFailure()

        let currentAbs = await gopAnalyzer.timeMs(for: key) ?? tPredMs
        let searchPoint = min(tPredMs, currentAbs)
        if cutEdge {
            currentDeltaGuardMs = min(currentDeltaGuardMs, frameDurationMs)
        }

        let allowFallback = failureCount >= 2 || cutEdge || (isBadData && failureCount == 1) || consecutiveBadData >= 3
        if allowFallback,
           let prevKey = await gopAnalyzer.prevSyncBefore(absMs: searchPoint, track: activeTrack),
           !quarantined.contains(prevKey),
           let prevAbs = await gopAnalyzer.timeMs(for: prevKey),
           let prevAccess = await gopAnalyzer.randomAccess(for: prevKey) {
            let candidate = FallbackCandidate(key: prevKey, absMs: prevAbs, access: prevAccess)
            if await chooseFallbackRA(targetAbsMs: tPredMs,
                                      candidate: candidate,
                                      randomAccess: &randomAccess,
                                      currentPrerollFrames: &currentPrerollFrames,
                                      minimalPrerollEnabled: minimalPrerollEnabled,
                                      reader: reader,
                                      cutEdge: cutEdge) {
                return true
            }
            return true
        }

        await forceReanchorNear(targetAbsMs: tPredMs,
                                 randomAccess: &randomAccess,
                                 currentPrerollFrames: &currentPrerollFrames,
                                 minimalPrerollEnabled: minimalPrerollEnabled,
                                 reader: reader,
                                 preferred: nil,
                                 overrideFreeze: true)
        if consecutiveBadData >= 3,
           let nextAbs = await gopAnalyzer.nextSyncAbsMs(after: tPredMs + frameDurationMs * 2, track: activeTrack),
           let nextResult = try? await gopAnalyzer.findRandomAccess(near: Double(nextAbs) / 1000.0,
                                                                    asset: activeAsset,
                                                                    track: activeTrack) {
            let candidate = FallbackCandidate(key: nextResult.key, absMs: nextAbs, access: nextResult)
            await adoptFallback(candidate: candidate,
                                targetAbsMs: targetAbsMs,
                                randomAccess: &randomAccess,
                                currentPrerollFrames: &currentPrerollFrames,
                                minimalPrerollEnabled: minimalPrerollEnabled,
                                reader: reader,
                                label: "skip-forward")
        }
        return true
    }
    
    private func trailingHold() -> Double {
        isHEVC ? 0.60 : 0.50
    }

    private func ms(from time: TimeInterval) -> Int64 {
        Int64((time * 1000.0).rounded())
    }

    private func isBadDataStatus(_ status: OSStatus) -> Bool {
        status == kVTVideoDecoderBadDataErr || status == OSStatus(kVTVideoDecoderUnsupportedDataFormatErr)
    }

    private func ensureCenteredOnce(_ targetAbsMs: Int64, reader: PersistentScrubReader) async {
        let now = Date()
        guard now > recenterCooldownUntil else { return }
        await reader.ensureCentered(around: targetAbsMs)
        recenterCooldownUntil = now.addingTimeInterval(recenterCooldown)
    }

    private func ensureProxyCoverageIfNeeded(targetAbsMs: Int64,
                                              cutEdge: Bool,
                                              reason: String) async {
        let now = Date()
        if let last = lastProxyEnsure {
            let timeDelta = now.timeIntervalSince(last.time)
            let absDelta = llabs(last.absMs - targetAbsMs)
            if timeDelta < 1.0 && absDelta < frameDurationMs * 6 {
                return
            }
        }

        let span: Int64 = cutEdge ? 6000 : 4000
        let context = cutEdge ? "cut-edge" : "decoder"
        let result = await proxyManager.ensureCoverageIfNeeded(clipID: clipID,
                                                               asset: originalAsset,
                                                               aroundAbsMs: targetAbsMs,
                                                               spanMs: span,
                                                               reason: reason,
                                                               context: context)
        if result.didRequestExport {
            lastProxyEnsure = (time: now, absMs: targetAbsMs)
            print("[PROXY_ENSURE] clip=\(clipID.uuidString.prefix(8)) span=\(span)ms status=\(result.status.rawValue) zone=\(result.zoneID?.uuidString.prefix(8) ?? "none")")
        }
        let deferDuration: TimeInterval
        switch result.status {
        case .ready:
            deferDuration = 0.45
        case .pending:
            deferDuration = cutEdge ? 1.2 : 0.9
        case .failed:
            deferDuration = 0.3
        case .missing:
            deferDuration = 0.2
        }

        if deferDuration > 0 {
            avoidOriginalUntil = Date().addingTimeInterval(deferDuration)
        }
    }

    private func shouldApplyCutEdgePolicy(targetAbsMs: Int64,
                                          tPredMs: Int64,
                                          randomAccess: GOPAnalyzer.RandomAccessResult) async -> Bool {
        let nearTarget = await gopAnalyzer.isNearCut(absMs: targetAbsMs, track: activeTrack)
        let nearPred = await gopAnalyzer.isNearCut(absMs: tPredMs, track: activeTrack)
        let failCount = await gopAnalyzer.failCountForKey(randomAccess.key)
        return nearTarget || nearPred || failCount >= 1
    }

    private func updateCutEdgeState(isActive: Bool, ra: RAKey, targetAbsMs: Int64) {
        if isActive {
            if !cutEdgeActive {
                cutEdgeActive = true
                cutEdgeWarmupDrops = 1
                cutEdgePresentGateActive = true
                cutEdgeDropsLogged = 0
                lastPresentedPTS = nil
                currentDeltaGuardMs = min(currentDeltaGuardMs, frameDurationMs)
                print("[CUT_EDGE_PREROLL] ra=\(ra) target=\(targetAbsMs) warmup=3 dropFirst=1 guard=\(currentDeltaGuardMs)ms")
            }
        } else if cutEdgeActive {
            cutEdgeActive = false
            cutEdgeWarmupDrops = 0
            cutEdgePresentGateActive = false
            cutEdgeDropsLogged = 0
        }
    }

    private func shouldDropFrameForCutEdge(pts: TimeInterval, targetAbsMs: Int64, ra: GOPAnalyzer.RandomAccessResult) -> Bool {
        guard cutEdgeActive else { return false }
        if cutEdgeWarmupDrops > 0 {
            cutEdgeWarmupDrops -= 1
            cutEdgeDropsLogged += 1
            print("[CUT_EDGE_DROP] reason=warmup remaining=\(cutEdgeWarmupDrops) pts=\(pts)")
            return true
        }

        if cutEdgePresentGateActive {
            let thresholdMs = max(targetAbsMs - 40, 0)
            let threshold = Double(thresholdMs) / 1000.0
            if pts < threshold {
                cutEdgeDropsLogged += 1
                print("[CUT_EDGE_DROP] reason=gated pts=\(pts) threshold=\(threshold)")
                return true
            }
            if let notSync = ra.flags.notSync, notSync {
                cutEdgeDropsLogged += 1
                print("[CUT_EDGE_DROP] reason=not-sync pts=\(pts)")
                return true
            }
            let prerollMs = (Double(targetAbsMs) / 1000.0 - pts) * 1000.0
            print("[WARMUP_DONE] shownAt=\(pts) dropped=\(cutEdgeDropsLogged) prerollMs=\(Int(prerollMs.rounded()))")
            cutEdgePresentGateActive = false
            cutEdgeDropsLogged = 0
        }

        return false
    }

    private func forceReanchorNear(targetAbsMs: Int64,
                                   randomAccess: inout GOPAnalyzer.RandomAccessResult,
                                   currentPrerollFrames: inout Int,
                                   minimalPrerollEnabled: Bool,
                                   reader: PersistentScrubReader,
                                   preferred: FallbackCandidate?,
                                   overrideFreeze: Bool = false) async {
        guard shouldAllowRecenter(label: "force_reanchor", override: overrideFreeze) else { return }
        if let preferred {
            if llabs(targetAbsMs - preferred.absMs) <= max(currentDeltaGuardMs, baseDeltaGuardMs) {
                await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                                       reason: "force-preferred")
                await proxyManager.ensureSpotProxy(clipID: clipID,
                                                    asset: originalAsset,
                                                    aroundAbsMs: targetAbsMs,
                                                    spanMs: 4000,
                                                    reason: "guard-exceeded",
                                                    context: "cut-edge",
                                                    raAnchorMs: preferred.absMs)
                if case .proxy = currentAssetKind, preferred.absMs == 0 {
                    await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
                } else {
                    await adoptFallback(candidate: preferred,
                                        targetAbsMs: targetAbsMs,
                                        randomAccess: &randomAccess,
                                        currentPrerollFrames: &currentPrerollFrames,
                                        minimalPrerollEnabled: minimalPrerollEnabled,
                                        reader: reader,
                                        label: "force_preferred")
                }
                return
            }
            if let altKey = await gopAnalyzer.prevSyncBefore(absMs: preferred.absMs - 1, track: activeTrack),
               altKey != preferred.key,
               let altAbs = await gopAnalyzer.timeMs(for: altKey),
               let altAccess = await gopAnalyzer.randomAccess(for: altKey) {
                await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                                       reason: "guard-exceeded")
                await proxyManager.ensureSpotProxy(clipID: clipID,
                                                    asset: originalAsset,
                                                    aroundAbsMs: targetAbsMs,
                                                    spanMs: 4000,
                                                    reason: "guard-exceeded",
                                                    context: "cut-edge",
                                                    raAnchorMs: altAbs)
                print("[CUT_EDGE_REANCHOR] fromRA=\(preferred.key) toRA=\(altKey) reason=guard-exceeded")
                let candidate = FallbackCandidate(key: altKey, absMs: altAbs, access: altAccess)
                if case .proxy = currentAssetKind, candidate.absMs == 0 {
                    await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
                } else {
                    await adoptFallback(candidate: candidate,
                                        targetAbsMs: targetAbsMs,
                                        randomAccess: &randomAccess,
                                        currentPrerollFrames: &currentPrerollFrames,
                                        minimalPrerollEnabled: minimalPrerollEnabled,
                                        reader: reader,
                                        label: "force_alt")
                }
                return
            }
        }

        if let raKey = await gopAnalyzer.prevSyncBefore(absMs: targetAbsMs, track: activeTrack),
           let raTime = await gopAnalyzer.timeMs(for: raKey),
           let raAccess = await gopAnalyzer.randomAccess(for: raKey) {
            await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                                   reason: "force-near")
            let candidate = FallbackCandidate(key: raKey, absMs: raTime, access: raAccess)
            if case .proxy = currentAssetKind, candidate.absMs == 0 {
                await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
            } else {
                await adoptFallback(candidate: candidate,
                                    targetAbsMs: targetAbsMs,
                                    randomAccess: &randomAccess,
                                    currentPrerollFrames: &currentPrerollFrames,
                                    minimalPrerollEnabled: minimalPrerollEnabled,
                                    reader: reader,
                                    label: "force_near")
            }
            return
        }

        print("[GOP_WIDEN] around t=\(targetAbsMs)ms")
        await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
        sameRAHits = 0
        lastTriedRA = nil
        lastRandomAccessKey = nil
    }

    private func onDecodeSuccess() {
        currentDeltaGuardMs = baseDeltaGuardMs
        sameRAHits = 0
        failureStreakKey = nil
        failureStreakCount = 0
        consecutiveProxyDecodeFailures = 0
        if currentAssetKind == .original {
            avoidOriginalUntil = .distantPast
        }
    }

    private func logDecodeContext(action: String, ra: GOPAnalyzer.RandomAccessResult, targetAbsMs: Int64) {
        let assetLabel = currentAssetKind.debugLabel
        let trackID = activeTrack.trackID
        print("[DECODE_ASSET] clip=\(clipID.uuidString.prefix(8)) action=\(action) asset=\(assetLabel) track=\(trackID) target=\(targetAbsMs)ms ra=\(ra.key)")
    }

    private func logDecodeFailure(status: OSStatus, ra: RAKey, targetAbsMs: Int64) {
        let assetLabel = currentAssetKind.debugLabel
        print("[DECODE_FAIL_CTX] clip=\(clipID.uuidString.prefix(8)) asset=\(assetLabel) status=\(status) target=\(targetAbsMs)ms ra=\(ra)")
    }

    private func shouldAllowRecenter(label: String, override: Bool = false) -> Bool {
        if override { return true }
        let now = Date()
        if now < recenterCooldownUntil {
            let remaining = recenterCooldownUntil.timeIntervalSince(now)
            let remainingMs = max(Int((remaining * 1000.0).rounded()), 0)
            print("[RECENTER_FREEZE] skip label=\(label) remaining_ms=\(remainingMs)")
            return false
        }
        return true
    }

    private func updateDeltaGuardAfterFailure() {
        let previous = currentDeltaGuardMs
        if currentDeltaGuardMs > 120 {
            currentDeltaGuardMs = 120
        } else if currentDeltaGuardMs > 80 {
            currentDeltaGuardMs = 80
        } else if currentDeltaGuardMs > 30 {
            currentDeltaGuardMs = 30
        }
        print("[FALLBACK_BACKOFF] guard now \(currentDeltaGuardMs)ms (was \(previous)ms)")
    }

    private func logAnalyzerRange() async {
        if let range = await gopAnalyzer.syncRangeMs(for: activeTrack) {
            print("[ANALYZER_RANGE] sync=[\(range.min), \(range.max)]ms")
        }
    }

    private func resetDecoderSession(reason: String, ra: RAKey) async {
        print("[DECODER_RESET] reason=\(reason) ra=\(ra)")
        await persistentVT?.flushAndReset()
        await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                               reason: reason)
        failureStreakCount = 0
        failureStreakKey = nil
        lastPresentedPTS = nil
        cutEdgeWarmupDrops = max(cutEdgeWarmupDrops, 2)
        cutEdgePresentGateActive = true
        cutEdgeDropsLogged = 0
    }

    private func switchAsset(to kind: AssetKind, proxyContext: ProxyContext?, reason: String) async -> Bool {
        guard currentAssetKind != kind else { return true }

        await persistentReader?.invalidate()
        persistentReader = nil

        await persistentVT?.flushAndReset()
        await persistentVT?.invalidate()
        persistentVT = nil

        await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                               reason: "asset-switch")

        switch kind {
        case .original:
            activeAsset = originalAsset
            activeTrack = originalTrack
            currentProxyContext = nil
        case .proxy(let zoneID):
            guard let context = proxyContext else {
                print("[SWITCH_ASSET] clip=\(clipID.uuidString.prefix(8)) to=proxy zone=\(zoneID) missing-context")
                return false
            }
            activeAsset = context.asset
            activeTrack = context.track
            currentProxyContext = context
        }

        currentAssetKind = kind
        let freezeMs: Double = 150
        recenterCooldownUntil = Date().addingTimeInterval(freezeMs / 1000.0)
        resetAfterSourceSwitch()
        await gopAnalyzer.resetAllCaches()
        print("[SWITCH_ASSET] clip=\(clipID.uuidString.prefix(8)) to=\(kind.debugLabel) reason=\(reason) freeze_ms=\(Int(freezeMs))")
        return true
    }

    func useProxySource(info: SpotProxyManager.ProxyInfo) async -> Bool {
        if let activeProxyZoneID, activeProxyZoneID == info.zoneID,
           let cached = proxyContexts[info.zoneID], cached.info.url == info.url {
            proxyContexts[info.zoneID] = ProxyContext(info: info, asset: cached.asset, track: cached.track)
            avoidOriginalUntil = .distantFuture
            return true
        }
        do {
            let context = try await proxyContext(for: info)
            activeProxyZoneID = info.zoneID
            let switched = await switchAsset(to: .proxy(zoneID: info.zoneID), proxyContext: context, reason: info.context)
            guard switched else {
                activeProxyZoneID = nil
                return false
            }
            avoidOriginalUntil = .distantFuture
            print("[SPOT_PROXY_APPLY] clip=\(clipID.uuidString.prefix(8)) zone=\(info.zoneID) context=\(info.context)")
            return true
        } catch {
            print("[SPOT_PROXY_FAIL] clip=\(clipID.uuidString.prefix(8)) zone=\(info.zoneID) error=\(error.localizedDescription) stage=prepare")
            let nsError = error as NSError
            let reason = (nsError.domain == "SpotProxy" && nsError.code == -6) ? "dimension-mismatch" : "prepare-failed"
            await proxyManager.markPlaybackFailure(clipID: clipID, zoneID: info.zoneID, reason: reason)
            return false
        }
    }

    func useOriginalSource() async {
        guard activeProxyZoneID != nil else { return }
        activeProxyZoneID = nil
        avoidOriginalUntil = .distantPast
        _ = await switchAsset(to: .original, proxyContext: nil, reason: "proxy-leave")
    }

    private func proxyContext(for info: SpotProxyManager.ProxyInfo) async throws -> ProxyContext {
        if let cached = proxyContexts[info.zoneID], cached.info.url == info.url {
            return cached
        }
        let asset = AVURLAsset(url: info.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw NSError(domain: "SpotProxy", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Proxy asset missing video track"])
        }
        let proxyDimensions = videoDimensions(for: track)
        if proxyDimensions.width != originalDimensions.width || proxyDimensions.height != originalDimensions.height {
            print("[SPOT_PROXY_DIM_MISMATCH] clip=\(clipID.uuidString.prefix(8)) expected=\(originalDimensions.width)x\(originalDimensions.height) got=\(proxyDimensions.width)x\(proxyDimensions.height)")
            throw NSError(domain: "SpotProxy", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Proxy resolution mismatch"])
        }
        let context = ProxyContext(info: info, asset: asset, track: track)
        proxyContexts[info.zoneID] = context
        return context
    }

    private func resetAfterSourceSwitch() {
        currentDeltaGuardMs = baseDeltaGuardMs
        sameRAHits = 0
        lastTriedRA = nil
        lastRandomAccessKey = nil
        failureStreakKey = nil
        failureStreakCount = 0
        cutEdgeActive = false
        cutEdgeWarmupDrops = 0
        cutEdgePresentGateActive = false
        cutEdgeDropsLogged = 0
        lastPresentedPTS = nil
        randomAccessCache.removeAll()
        randomAccessCacheOrder.removeAll()
        deadlineAttemptHistory.removeAll()
    }

    private struct FallbackCandidate {
        let key: RAKey
        let absMs: Int64
        let access: GOPAnalyzer.RandomAccessResult
    }

    private struct ProxyContext {
        let info: SpotProxyManager.ProxyInfo
        let asset: AVURLAsset
        let track: AVAssetTrack
    }

    private func videoDimensions(for track: AVAssetTrack) -> CMVideoDimensions {
        if let descriptions = track.formatDescriptions as? [CMFormatDescription],
           let format = descriptions.first {
            return CMVideoFormatDescriptionGetDimensions(format)
        }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CMVideoDimensions(width: Int32(abs(transformed.width)),
                                 height: Int32(abs(transformed.height)))
    }

    func warmRandomAccess(around targetAbsMs: Int64, spreadMs: Int64 = 500) async {
        let clampedSpread = max(spreadMs, 0)
        let offsets: [Int64] = [-clampedSpread, 0, clampedSpread]
        var warmedKeys = Set<RAKey>()
        let launchEpoch = await gopAnalyzer.currentEpoch()

        for offset in offsets {
            let target = max(targetAbsMs &+ offset, 0)
            let seconds = Double(target) / 1000.0

            do {
                let result = try await gopAnalyzer.findRandomAccess(near: seconds,
                                                                    asset: activeAsset,
                                                                    track: activeTrack)
                guard await gopAnalyzer.currentEpoch() == launchEpoch else { return }
                rememberRandomAccess(result, targetTime: seconds)
                warmedKeys.insert(result.key)
            } catch {
                if offset == 0 {
                    print("[WARM_RA_FIND_FAIL] time=\(seconds) offset=\(offset) error=\(error)")
                }
            }

            let backtrackSeconds = max(seconds - 0.001, 0)
            do {
                if let previous = try await gopAnalyzer.previousRandomAccess(before: backtrackSeconds,
                                                                              asset: activeAsset,
                                                                              track: activeTrack) {
                    guard await gopAnalyzer.currentEpoch() == launchEpoch else { return }
                    rememberRandomAccess(previous, targetTime: backtrackSeconds)
                    warmedKeys.insert(previous.key)
                }
            } catch {
                // Prior RA is a best-effort warmup; ignore failures
            }
        }

        guard await gopAnalyzer.currentEpoch() == launchEpoch else { return }
        for key in warmedKeys {
            if let absMs = await gopAnalyzer.timeMs(for: key) {
                guard await gopAnalyzer.currentEpoch() == launchEpoch else { return }
                _ = await gopAnalyzer.prevSyncBefore(absMs: absMs, track: activeTrack)
            }
        }
    }

    private func chooseFallbackRA(targetAbsMs: Int64,
                                  candidate: FallbackCandidate,
                                  randomAccess: inout GOPAnalyzer.RandomAccessResult,
                                  currentPrerollFrames: inout Int,
                                  minimalPrerollEnabled: Bool,
                                  reader: PersistentScrubReader,
                                  cutEdge: Bool) async -> Bool {
        let delta = targetAbsMs - candidate.absMs
        print("[RA_CANDIDATE] target=\(targetAbsMs)ms ra=\(candidate.absMs)ms Δ=\(delta)ms guard=\(currentDeltaGuardMs)ms")

        if case .proxy = currentAssetKind, candidate.absMs == 0 {
            guard shouldAllowRecenter(label: "proxy_zero") else { return false }
            await reader.widenAroundAbsMs(targetAbsMs, trailingHold: trailingHold())
            await forceReanchorNear(targetAbsMs: targetAbsMs,
                                     randomAccess: &randomAccess,
                                     currentPrerollFrames: &currentPrerollFrames,
                                     minimalPrerollEnabled: minimalPrerollEnabled,
                                     reader: reader,
                                     preferred: nil,
                                     overrideFreeze: true)
            return false
        }

        if lastTriedRA == candidate.key {
            sameRAHits += 1
            print("[RA_LOOP] key=\(candidate.key) hits=\(sameRAHits)")
            if sameRAHits >= 2 {
                if cutEdge,
                   let altKey = await gopAnalyzer.prevSyncBefore(absMs: candidate.absMs - 1, track: activeTrack),
                   altKey != candidate.key,
                   let altAbs = await gopAnalyzer.timeMs(for: altKey),
                   let altAccess = await gopAnalyzer.randomAccess(for: altKey) {
                    await admissionController.releaseReverseSlotOnCutEdge(clipID: clipID,
                                                                           reason: "ra-retries")
                    await proxyManager.ensureSpotProxy(clipID: clipID,
                                                        asset: originalAsset,
                                                        aroundAbsMs: targetAbsMs,
                                                        spanMs: 4000,
                                                        reason: "ra-retries",
                                                        context: "cut-edge",
                                                        raAnchorMs: candidate.absMs)
                    print("[CUT_EDGE_REANCHOR] fromRA=\(candidate.key) toRA=\(altKey) reason=same-ra-failed-twice")
                    let altCandidate = FallbackCandidate(key: altKey, absMs: altAbs, access: altAccess)
                    await adoptFallback(candidate: altCandidate,
                                        targetAbsMs: targetAbsMs,
                                        randomAccess: &randomAccess,
                                        currentPrerollFrames: &currentPrerollFrames,
                                        minimalPrerollEnabled: minimalPrerollEnabled,
                                        reader: reader,
                                        label: "cut_edge_retry")
                    return false
                }
                await forceReanchorNear(targetAbsMs: targetAbsMs,
                                         randomAccess: &randomAccess,
                                         currentPrerollFrames: &currentPrerollFrames,
                                         minimalPrerollEnabled: minimalPrerollEnabled,
                                         reader: reader,
                                         preferred: candidate,
                                         overrideFreeze: true)
                return false
            }
        } else {
            lastTriedRA = candidate.key
            sameRAHits = 0
        }

        let allowedDelta = activeProxyZoneID != nil ? max(currentDeltaGuardMs, 5000) : currentDeltaGuardMs
        if llabs(delta) > allowedDelta {
            print("[RA_TOO_OLD] Δ=\(delta)ms > guard=\(allowedDelta)ms → reanchor")
            await forceReanchorNear(targetAbsMs: targetAbsMs,
                                     randomAccess: &randomAccess,
                                     currentPrerollFrames: &currentPrerollFrames,
                                     minimalPrerollEnabled: minimalPrerollEnabled,
                                     reader: reader,
                                     preferred: candidate,
                                     overrideFreeze: true)
            return false
        }

        if minimalPrerollEnabled {
            let bump = codec == .hevc ? 2 : 1
            let fallbackPreroll = codec == .hevc ? 6 : 4
            currentPrerollFrames = max(currentPrerollFrames + bump, fallbackPreroll)
        }

        randomAccess = candidate.access
        rememberRandomAccess(candidate.access, targetTime: Double(targetAbsMs) / 1000.0)
        lastRandomAccessKey = candidate.key

        await reader.slide(aroundAbsMs: candidate.absMs, trailingHold: trailingHold())
        await ensureCenteredOnce(candidate.absMs, reader: reader)
        print("[GOP_FALLBACK_TIME] t=\(targetAbsMs)ms -> ra=\(candidate.key) Δ=\(delta)ms")
        return true
    }

    private func backoffAfterDoubleFailure(failingKey: RAKey,
                                           targetAbsMs: Int64,
                                           randomAccess: inout GOPAnalyzer.RandomAccessResult,
                                           currentPrerollFrames: inout Int,
                                           minimalPrerollEnabled: Bool,
                                           reader: PersistentScrubReader,
                                           quarantined: inout Set<RAKey>) async -> Bool {
        guard let failingAbsMs = await gopAnalyzer.timeMs(for: failingKey) else {
            return false
        }

        let frameStep = max(frameDurationMs, 16)
        var searchAbs = max(failingAbsMs - frameStep * 2, 0)
        var attempts = 0
        let maxAttempts = 8

        while attempts < maxAttempts {
            guard let candidateKey = await gopAnalyzer.prevSyncBefore(absMs: searchAbs, track: activeTrack) else {
                break
            }
            if candidateKey == failingKey || quarantined.contains(candidateKey) {
                searchAbs = max(searchAbs - frameStep * Int64(attempts + 2), 0)
                attempts += 1
                continue
            }
            guard let candidateAbs = await gopAnalyzer.timeMs(for: candidateKey),
                  let candidateAccess = await gopAnalyzer.randomAccess(for: candidateKey) else {
                searchAbs = max(searchAbs - frameStep * Int64(attempts + 2), 0)
                attempts += 1
                continue
            }

            let candidate = FallbackCandidate(key: candidateKey, absMs: candidateAbs, access: candidateAccess)
            await adoptFallback(candidate: candidate,
                               targetAbsMs: targetAbsMs,
                               randomAccess: &randomAccess,
                               currentPrerollFrames: &currentPrerollFrames,
                               minimalPrerollEnabled: minimalPrerollEnabled,
                               reader: reader,
                               label: "bad_data_double")
            quarantined.insert(candidateKey)
            await reader.freezeRecentering(for: 0.2, reason: "bad-data-double")
            print("[RA_BACKOFF] failing=\(failingKey) alt=\(candidateKey) attempts=\(attempts + 1)")
            return true
        }

        return false
    }

    private func adoptFallback(candidate: FallbackCandidate,
                               targetAbsMs: Int64,
                               randomAccess: inout GOPAnalyzer.RandomAccessResult,
                               currentPrerollFrames: inout Int,
                               minimalPrerollEnabled: Bool,
                               reader: PersistentScrubReader?,
                               label: String) async {
        let guardMs = max(currentDeltaGuardMs, baseDeltaGuardMs)
        var chosen = candidate

        var attempts = 0
        while chosen.absMs > targetAbsMs {
            guard let prevKey = await gopAnalyzer.prevSyncBefore(absMs: chosen.absMs - 1, track: activeTrack),
                  prevKey != chosen.key,
                  let prevAbs = await gopAnalyzer.timeMs(for: prevKey),
                  let prevAccess = await gopAnalyzer.randomAccess(for: prevKey) else {
                break
            }
            print("[GOP_REANCHOR_BACK] target=\(targetAbsMs)ms candidate=\(chosen.absMs)ms prev=\(prevAbs)ms")
            chosen = FallbackCandidate(key: prevKey, absMs: prevAbs, access: prevAccess)
            attempts += 1
            if attempts >= 12 { break }
        }

        if chosen.absMs - targetAbsMs > guardMs {
            if let altKey = await gopAnalyzer.prevSyncBefore(absMs: targetAbsMs, track: activeTrack),
               altKey != chosen.key,
               let altAbs = await gopAnalyzer.timeMs(for: altKey),
               let altAccess = await gopAnalyzer.randomAccess(for: altKey) {
                print("[GOP_REANCHOR_ALT] target=\(targetAbsMs)ms candidate=\(chosen.absMs)ms guard=\(guardMs)ms alt=\(altAbs)ms")
                chosen = FallbackCandidate(key: altKey, absMs: altAbs, access: altAccess)
            } else {
                print("[GOP_REANCHOR_WARN] unable to clamp candidate=\(chosen.absMs)ms to <= target=\(targetAbsMs)ms guard=\(guardMs)ms")
            }
        }

        let delta = targetAbsMs - chosen.absMs
        print("[GOP_FORCE_REANCHOR] t=\(targetAbsMs)ms -> ra=\(chosen.absMs)ms Δ=\(delta)ms label=\(label)")
        print("[GOP_RECENTER_TIME] t=\(targetAbsMs)ms -> ra=\(chosen.key)")
        var sanitized = chosen.access
        if !sanitized.pts.isFinite {
            sanitized = GOPAnalyzer.RandomAccessResult(
                pts: Double(chosen.absMs) / 1000.0,
                key: sanitized.key,
                kind: sanitized.kind,
                flags: sanitized.flags,
                isFallback: sanitized.isFallback,
                requiresPreroll: sanitized.requiresPreroll
            )
        }
        randomAccess = sanitized
        rememberRandomAccess(sanitized, targetTime: Double(targetAbsMs) / 1000.0)
        lastRandomAccessKey = chosen.key
        lastTriedRA = chosen.key
        sameRAHits = 0
        failureStreakKey = chosen.key
        failureStreakCount = 0
        if minimalPrerollEnabled {
            let boost = codec == .hevc ? 3 : 2
            let fallbackPreroll = codec == .hevc ? 6 : 4
            currentPrerollFrames = max(currentPrerollFrames + boost, fallbackPreroll)
        }
        if let reader {
            await reader.slide(aroundAbsMs: chosen.absMs, trailingHold: trailingHold(), label: "recenter")
            await ensureCenteredOnce(chosen.absMs, reader: reader)
            await reader.freezeRecentering(for: 0.15, reason: "new-anchor")
        } else {
            recenterCooldownUntil = Date().addingTimeInterval(0.15)
        }
        await persistentVT?.flushAndReset()
        logDecodeContext(action: "retry", ra: randomAccess, targetAbsMs: targetAbsMs)
        currentDeltaGuardMs = max(min(currentDeltaGuardMs, frameDurationMs), 16)
    }
    
    // MARK: - Supporting Types
    
    struct DecodeStages {
        var initMS: Double = 0
        var seekIDRMS: Double = 0
        var prerollMS: Double = 0
        var firstSampleMS: Double = 0
        var decodeMS: Double = 0
        var convertMS: Double = 0
        var cacheWriteMS: Double = 0
        
        var totalMS: Double {
            initMS + seekIDRMS + prerollMS + firstSampleMS + decodeMS + convertMS + cacheWriteMS
        }
    }
}

// MARK: - Convenience API

extension EnhancedScrubDecoder {
    func decodeFrameSimple(at targetTime: TimeInterval,
                           tPred: TimeInterval,
                           direction: ScrubCoordinator.ScrubDirection,
                           deadline: Bool = false) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        // CRITICAL: Use VT Hardware Decoder ONLY - no ImageGenerator fallback!
        // ImageGenerator is too slow (2400ms vs 50ms) for real-time scrubbing
        let result = try await decodeFrame(at: targetTime, tPred: tPred, direction: direction, deadlineMode: deadline)
        return (result.pixelBuffer, result.pts)
        
        // OLD CODE: ImageGenerator fallback removed - was causing 2.4s decode times!
        // do {
        //     let result = try await decodeFrame(at: targetTime, tPred: tPred, direction: direction)
        //     return (result.pixelBuffer, result.pts)
        // } catch {
        //     // REMOVED: ImageGenerator fallback - too slow for scrubbing!
        //     let nsError = error as NSError
        //     if nsError.code == -12785 || nsError.domain == "AVFoundationErrorDomain" {
        //         await MainActor.run {
        //             print("[DECODER_12785_FALLBACK] AVAssetReader failed (\(nsError.code)), using ImageGenerator")
        //         }
        //         return try await decodeWithImageGenerator(at: targetTime)
        //     }
        //     throw error
        // }
    }

    func resetForTimelineJump(targetTime: TimeInterval) async {
        let targetAbsMs = max(ms(from: targetTime), 0)
        print("[COLD_RESET] clip=\(clipID.uuidString.prefix(8)) target_ms=\(targetAbsMs)")

        if let reader = persistentReader {
            await reader.invalidate()
            persistentReader = nil
        }

        if let vtSession = persistentVT {
            await vtSession.flushAndReset()
            await vtSession.invalidate()
            persistentVT = nil
        }

        if let engine = compressedEngine {
            await engine.invalidate()
            compressedEngine = nil
            compressedEngineTrackID = 0
        }

        resetAfterSourceSwitch()

        let warmSpread: Int64 = 900
        await warmRandomAccess(around: targetAbsMs, spreadMs: warmSpread)
    }

    /// CRITICAL FIX: Force complete reset when VT decoder is stuck
    /// More aggressive than resetForTimelineJump - clears all caches and state
    func forceCompleteReset(targetTime: TimeInterval) async {
        let targetAbsMs = max(ms(from: targetTime), 0)
        print("[FORCE_COMPLETE_RESET] clip=\(clipID.uuidString.prefix(8)) target_ms=\(targetAbsMs)")

        // Invalidate ALL persistent resources
        if let reader = persistentReader {
            await reader.invalidate()
            persistentReader = nil
        }

        if let vtSession = persistentVT {
            await vtSession.flushAndReset()
            await vtSession.invalidate()
            persistentVT = nil
        }

        if let engine = compressedEngine {
            await engine.invalidate()
            compressedEngine = nil
            compressedEngineTrackID = 0
        }

        // Clear ALL cached state
        randomAccessCache.removeAll()
        randomAccessCacheOrder.removeAll()
        lastRandomAccessKey = nil
        lastTriedRA = nil
        sameRAHits = 0
        failureStreakKey = nil
        failureStreakCount = 0
        deadlineAttemptHistory.removeAll()

        // Reset cut-edge state
        cutEdgeActive = false
        cutEdgeWarmupDrops = 0
        cutEdgeDropsLogged = 0
        cutEdgePresentGateActive = false
        currentDeltaGuardMs = baseDeltaGuardMs

        // Reset proxy state
        lastProxyEnsure = nil
        avoidOriginalUntil = .distantPast
        consecutiveProxyDecodeFailures = 0

        resetAfterSourceSwitch()

        // Don't warm random access - let next decode find fresh IDR
        print("[FORCE_COMPLETE_RESET] All state cleared, ready for fresh decode")
    }
    
    private func decodeWithImageGenerator(at targetTime: TimeInterval) async throws -> (CVPixelBuffer, TimeInterval) {
        let generator = AVAssetImageGenerator(asset: activeAsset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: targetTime, preferredTimescale: 24000)
        var actualTime: CMTime = .zero
        
        let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
        let pixelBuffer = try convertCGImageToPixelBuffer(cgImage)
        
        await MainActor.run {
            print("[IMAGE_GENERATOR] Decoded frame at \(String(format: "%.3f", actualTime.seconds))s")
        }
        
        return (pixelBuffer, actualTime.seconds)
    }
    
    private func convertCGImageToPixelBuffer(_ cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "EnhancedScrubDecoder", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw NSError(domain: "EnhancedScrubDecoder", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
    }

    func shouldAvoidOriginal() -> Bool {
        Date() < avoidOriginalUntil
    }

    nonisolated func nativeFrameDuration() -> Double {
        frameDuration
    }

    private static func deriveFrameDuration(from track: AVAssetTrack) -> Double {
        if track.minFrameDuration.isValid && !track.minFrameDuration.isIndefinite && track.minFrameDuration.seconds > 0 {
            return track.minFrameDuration.seconds
        }
        let fps = track.nominalFrameRate
        if fps > 0 {
            return 1.0 / Double(fps)
        }
        return 1.0 / 24.0
    }

    private static func deriveRecommendedPrerollFrames(for track: AVAssetTrack) -> Int {
        guard let formatDescriptions = track.formatDescriptions as? [CMFormatDescription],
              let formatDescription = formatDescriptions.first else {
            return 4  // Increased default from 3
        }

        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
        if codecType == kCMVideoCodecType_HEVC {
            return 8  // Increased from 5 to reduce decode errors with HEVC
        }

        return 5  // Increased H.264 default from 3
    }
}
