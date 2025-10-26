import Foundation
import AVFoundation
import CoreVideo

/// Global override to force the stabilized reverse scrub path (v2).
/// When enabled we bypass legacy gates that still default to version 1 behavior.
enum StableScrubMode {
    static let enabled = true
}

/// Integrated scrub pipeline combining Phase 3 (Core) and Phase 2 (Minimal-Set).
/// Orchestrates all components for smooth reverse scrubbing with minimal latency.
@MainActor
final class IntegratedScrubPipeline {
    private struct DecodeTarget {
        let pts: TimeInterval
        let storeInPrimary: Bool
        let reason: String
    }

    private struct ReverseCursorSnapshot {
        let pts: TimeInterval
        let index: Int
        let requestedIndex: Int
        let didResetForDirectionChange: Bool
    }

    private enum ReverseCursorAccessMode {
        case advance
        case observe(reference: Int?)
    }
    
    // MARK: - Properties
    
    private let flags = ScrubFeatureFlags.shared
    private let config: ScrubFeatureFlags.Config
    
    // Phase 3 components - IMAGE GENERATOR decoder (perfect for scrubbing!)
    private var decoders: [UUID: EnhancedScrubDecoder] = [:]
    
    // Phase 2 components
    private var velocityPredictor: VelocityPredictor
    private var gopManagers: [UUID: GOPCoalescingManager] = [:]
    private let gopAnalyzer = GOPAnalyzer()
    private var admissionController: AdmissionController
    private var landingZoneManager: LandingZoneManager
    private let proxyManager = SpotProxyManager.shared
    private var clipSources: [UUID: (asset: AVAsset, track: AVAssetTrack)] = [:]
    private var stickyProxyHoldUntil: [UUID: CFAbsoluteTime] = [:]
    private var activeSources: [UUID: DecodeSource] = [:]
    private var activeProxyInfo: [UUID: SpotProxyManager.ProxyInfo] = [:]
    private var repairTasks: [UUID: [Int64: Task<Void, Never>]] = [:]
    private let proxyHoldDuration: CFTimeInterval = 1.5
    private var reverseFrameCursor: [UUID: Int] = [:]
    private var lastDirectionChangeTime: [UUID: CFAbsoluteTime] = [:]
    private var lastRequestedIndex: [UUID: Int] = [:]
    private var reverseFailureStreak: [UUID: Int] = [:]
    private var reverseRecoveryAnchor: [UUID: TimeInterval] = [:]
    private var coldResetPending: Set<UUID> = []
    private var decodeSuccessCount: [UUID: Int] = [:]

    private enum DecodeSource: Equatable {
        case original
        case proxy(UUID)
    }

    // State
    private var currentEpoch: UInt64 = 0
    private var isActive: Bool = false
    private var lastIdleTime: CFAbsoluteTime = 0
    private let stopIdleThreshold: TimeInterval = 0.2  // 200ms
    private var repairInflight: [UUID: Set<Int64>] = [:]
    private var recentDecodeDelta: [UUID: Double] = [:]
    private var decoderErrorStreak: [UUID: Int] = [:]
    nonisolated private var stableReverse: Bool { StableScrubMode.enabled }
    
    // DEBOUNCING: Prevent race condition where tasks are cancelled immediately
    private var lastDecodeStartTime: [UUID: CFAbsoluteTime] = [:]
    private let minDecodeInterval: TimeInterval = 0.030  // 30ms minimum between decode starts
    
    // TASK MANAGEMENT: Track active decode tasks for proper cancellation
    private var activeDecodeTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    private enum SourceOverrideMode {
        case preferProxy
    }
    private struct SourceOverrideState {
        var mode: SourceOverrideMode
        var expiry: CFAbsoluteTime
        var lastRequest: CFAbsoluteTime
    }
    private var sourceOverrides: [UUID: SourceOverrideState] = [:]

    // STUCK DETECTION: Prevent race condition where multiple threads detect stuck tasks simultaneously
    private var stuckDetectionInProgress: Set<UUID> = []
    private var lastStuckDetectionTime: [UUID: CFAbsoluteTime] = [:]

    private func scheduleDecodeTask(clipID: UUID,
                                     direction: ScrubCoordinator.ScrubDirection,
                                     execute: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let jobID = UUID()
        var watchdogTask: Task<Void, Never>?
        let trackedTask = Task { [weak self] in
            defer {
                watchdogTask?.cancel()
                if let self {
                    Task { await self.finishDecodeJob(clipID: clipID, jobID: jobID) }
                }
            }
            await execute()
        }

        if activeDecodeTasks[clipID] == nil {
            activeDecodeTasks[clipID] = [:]
        }
        activeDecodeTasks[clipID]?[jobID] = trackedTask

        if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled && direction == .reverse {
            let config = ScrubFeatureFlags.shared.config
            let fallbackMs = max(config.reverseWatchdogTimeout * 1000.0, 180.0)
            let derivedMs: Double
            if let p95 = ScrubTelemetry.shared.currentDecodeP95() {
                derivedMs = max(3.0 * p95, 180.0)
            } else {
                derivedMs = fallbackMs
            }
            let timeout = derivedMs / 1000.0
            watchdogTask = Task { [weak self] in
                guard timeout > 0 else { return }
                await MainActor.run {
                    ScrubTelemetry.shared.logWatchdog(timeoutMs: derivedMs, action: "logOnly")
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                guard let self else { return }
                if trackedTask.isCancelled { return }
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logWatchdog(clipID: clipID,
                                                               reason: "timeout")
                }
            }
        }
        return trackedTask
    }
    
    @MainActor
    private func finishDecodeJob(clipID: UUID, jobID: UUID) {
        guard var jobs = activeDecodeTasks[clipID] else { return }
        jobs.removeValue(forKey: jobID)
        if jobs.isEmpty {
            activeDecodeTasks.removeValue(forKey: clipID)
        } else {
            activeDecodeTasks[clipID] = jobs
        }
    }

    private func proxyOverrideActive(for clipID: UUID, now: CFAbsoluteTime) -> Bool {
        guard var override = sourceOverrides[clipID] else { return false }
        if override.expiry <= now {
            sourceOverrides.removeValue(forKey: clipID)
            return false
        }
        sourceOverrides[clipID] = override
        return true
    }

    private func clearProxyOverride(for clipID: UUID) {
        sourceOverrides.removeValue(forKey: clipID)
    }

    private func activateProxyOverride(clipID: UUID, targetMs: Int64, reason: String) async {
        let now = CFAbsoluteTimeGetCurrent()
        guard let clipAsset = clipSources[clipID]?.asset else { return }
        if var existing = sourceOverrides[clipID] {
            if existing.expiry <= now {
                sourceOverrides.removeValue(forKey: clipID)
            } else {
                if now - existing.lastRequest >= 0.25 {
                    existing.lastRequest = now
                    sourceOverrides[clipID] = existing
                    await proxyManager.ensureSpotProxy(clipID: clipID,
                                                       asset: clipAsset,
                                                       aroundAbsMs: targetMs,
                                                       spanMs: 4000,
                                                       reason: reason,
                                                       context: "override")
                }
                return
            }
        }
        let expiry = now + config.reverseProxyOverrideLifespan
        sourceOverrides[clipID] = SourceOverrideState(mode: .preferProxy,
                                                      expiry: expiry,
                                                      lastRequest: now)
        if ScrubFeatureFlags.shared.verboseLogging {
            print("[PROXY_OVERRIDE] clip=\(clipID.uuidString.prefix(8)) reason=\(reason) target_ms=\(targetMs) expiry=\(String(format: "%.2f", expiry - now))")
        }
        await proxyManager.ensureSpotProxy(clipID: clipID,
                                           asset: clipAsset,
                                           aroundAbsMs: targetMs,
                                           spanMs: 4000,
                                           reason: reason,
                                           context: "override")
    }
    
    // MARK: - Initialization
    
    init(config: ScrubFeatureFlags.Config? = nil) {
        let finalConfig = config ?? ScrubFeatureFlags.shared.config
        self.config = finalConfig
        self.velocityPredictor = VelocityPredictor(config: finalConfig)
        self.admissionController = AdmissionController(config: finalConfig)
        self.landingZoneManager = LandingZoneManager(config: finalConfig)
    }

    // MARK: - Lifecycle

    /// Begins scrub operation.
    func beginScrub(clips: [UUID: (asset: AVAsset, track: AVAssetTrack)]) async {
        let previousSources = clipSources
        for (clipID, previous) in previousSources {
            if clips[clipID] == nil {
                await cancelInflightDecodes(for: clipID)
                await proxyManager.invalidateClip(clipID, reason: "timeline-remove")
                activeSources[clipID] = nil
                activeProxyInfo[clipID] = nil
                stickyProxyHoldUntil[clipID] = nil
                repairTasks[clipID] = nil
                repairInflight[clipID] = nil
            }
        }
        for (clipID, clipData) in clips {
            if let previous = previousSources[clipID],
               !(previous.asset === clipData.asset && previous.track.trackID == clipData.track.trackID) {
                await cancelInflightDecodes(for: clipID)
                await proxyManager.invalidateClip(clipID, reason: "timeline-change")
                activeSources[clipID] = .original
                activeProxyInfo[clipID] = nil
                stickyProxyHoldUntil[clipID] = nil
                repairTasks[clipID] = nil
                repairInflight[clipID] = nil
            }
        }
        clipSources = clips

        currentEpoch &+= 1
        isActive = true
        lastIdleTime = CFAbsoluteTimeGetCurrent()

        velocityPredictor.reset()
        await admissionController.resetAll()
        recentDecodeDelta.removeAll()
        decoderErrorStreak.removeAll()
        reverseFailureStreak.removeAll()
        reverseRecoveryAnchor.removeAll()
        stickyProxyHoldUntil.removeAll()
        reverseFrameCursor.removeAll()
        lastDirectionChangeTime.removeAll()
        lastRequestedIndex.removeAll()
        lastDecodeStartTime.removeAll()
        coldResetPending.removeAll()
        decodeSuccessCount.removeAll()
        sourceOverrides.removeAll()

        // Create decoders and GOP managers
        for (clipID, clipData) in clips {
            let decoder = EnhancedScrubDecoder(asset: clipData.asset,
                                               track: clipData.track,
                                               clipID: clipID,
                                               config: config,
                                               gopAnalyzer: gopAnalyzer,
                                               admissionController: admissionController,
                                               proxyManager: proxyManager)
            decoders[clipID] = decoder
            gopManagers[clipID] = GOPCoalescingManager(clipID: clipID, config: config)
            activeSources[clipID] = .original
            activeProxyInfo[clipID] = nil
            stickyProxyHoldUntil[clipID] = nil
            decodeSuccessCount[clipID] = 0
        }
        
        if flags.telemetryEnabled {
            print("[IntegratedScrubPipeline] Begin scrub epoch=\(currentEpoch) clips=\(clips.count)")
        }
        
        for clipID in clips.keys {
            await admissionController.startBurst(clipID: clipID)
        }
    }
    
    /// Updates scrub position with velocity.
    func updateScrub(tNow: TimeInterval, velocity: Double, direction: ScrubCoordinator.ScrubDirection) async {
        guard isActive else { return }
        lastIdleTime = CFAbsoluteTimeGetCurrent()
        
        // Phase 2.2: Predict target with improved EMA smoothing
        let prediction = flags.velocityPrediction ?
            velocityPredictor.predict(tNow: tNow, rawVelocity: velocity) :
            VelocityPredictor.Prediction(tNow: tNow,
                                         tPred: tNow,
                                         velocityFPS: velocity,
                                         smoothedVelocity: velocity,
                                         windowFrames: 2)
        
        // Phase 2.3: Calculate landing zone with adaptive window from prediction
        for (clipID, decoder) in decoders {
            await decodeForClip(clipID: clipID,
                                decoder: decoder,
                                tNow: tNow,
                                tPred: prediction.tPred,
                                direction: direction,
                                adaptiveWindowFrames: prediction.windowFrames,
                                velocityFPS: prediction.smoothedVelocity)
        }
    }
    
    /// Ends scrub operation with deadline decode.
    func endScrub(tFinal: TimeInterval) async {
        isActive = false
        
        if flags.telemetryEnabled {
            print("[IntegratedScrubPipeline] End scrub at t=\(String(format: "%.3f", tFinal))")
        }
        
        await ensureMandatoryDecodes(tFinal: tFinal)

        if flags.deadlineDecode {
            let stopStart = CFAbsoluteTimeGetCurrent()
            
            await withTaskGroup(of: Void.self) { group in
                for (clipID, decoder) in decoders {
                    group.addTask {
                        await self.deadlineDecodeForClip(clipID: clipID,
                                                         decoder: decoder,
                                                         tFinal: tFinal)
                    }
                }
            }
            
            let stopDuration = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
            ScrubTelemetry.shared.logStopMetric(ScrubTelemetry.StopMetricLog(timestamp: CFAbsoluteTimeGetCurrent(),
                                                                             direction: .reverse,  // TODO: Track actual direction
                                                                             timeToExactFrameMS: stopDuration))
        }
        
        for manager in gopManagers.values {
            await manager.cancelJob()
        }
        
        for decoder in decoders.values {
            await decoder.invalidate()
        }
        for clipID in decoders.keys {
            await proxyManager.clearActiveHit(for: clipID)
        }

        decoders.removeAll()
        gopManagers.removeAll()
        recentDecodeDelta.removeAll()
        decoderErrorStreak.removeAll()
        reverseFailureStreak.removeAll()
        reverseRecoveryAnchor.removeAll()
        stickyProxyHoldUntil.removeAll()
        reverseFrameCursor.removeAll()
        lastDirectionChangeTime.removeAll()
        lastRequestedIndex.removeAll()
        lastDecodeStartTime.removeAll()
        clipSources.removeAll()
        activeSources.removeAll()
        activeProxyInfo.removeAll()
        repairTasks.removeAll()
        decodeSuccessCount.removeAll()
        sourceOverrides.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func ensureMandatoryDecodes(tFinal: TimeInterval) async {
        guard config.mandatoryDecodeEnabled else { return }
        var pending = decoders.keys.filter { decodeSuccessCount[$0, default: 0] == 0 }
        guard !pending.isEmpty else { return }
        var attempt = 0
        var retries = 0
        while !pending.isEmpty && attempt < config.mandatoryDecodeMaxRetries {
            attempt += 1
            if attempt > 1 {
                retries += 1
            }
            await withTaskGroup(of: Void.self) { group in
                for clipID in pending {
                    guard let decoder = decoders[clipID] else { continue }
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.deadlineDecodeForClip(clipID: clipID,
                                                          decoder: decoder,
                                                          tFinal: tFinal)
                    }
                }
            }
            pending = decoders.keys.filter { decodeSuccessCount[$0, default: 0] == 0 }
        }
        let successCount = decoders.keys.filter { decodeSuccessCount[$0, default: 0] > 0 }.count
        ScrubTelemetry.shared.logMandatorySummary(successCount: successCount,
                                                  retries: retries)
    }

    private func decodeForClip(clipID: UUID,
                                decoder: EnhancedScrubDecoder,
                                tNow: TimeInterval,
                                tPred: TimeInterval,
                                direction: ScrubCoordinator.ScrubDirection,
                                adaptiveWindowFrames: Int,
                                velocityFPS: Double) async {
        print("[DECODE_FOR_CLIP] clipID=\(clipID.uuidString.prefix(8)) hasGOPManager=\(gopManagers[clipID] != nil)")
        guard let gopManager = gopManagers[clipID] else { return }
        
        // DEBOUNCING FIX: Prevent race condition where tasks are cancelled immediately after start
        let now = CFAbsoluteTimeGetCurrent()
        let frameDuration = decoder.nativeFrameDuration()
        let lastDecodeDelta = recentDecodeDelta[clipID]
        let overrideActive = proxyOverrideActive(for: clipID, now: now)

        let landingZone = flags.landingZones ?
            landingZoneManager.calculateLandingZone(tPred: tPred,
                                                    velocityFPS: velocityFPS,
                                                    direction: direction,
                                                    frameDuration: frameDuration,
                                                    adaptiveWindowFrames: adaptiveWindowFrames,
                                                    recentDecodeDelta: lastDecodeDelta,
                                                    currentTime: tNow) : nil

        var warmBehind = 0
        var warmAhead = 0
        if let landingZone {
            warmBehind = TransportController.shared.warmFrameCount(for: clipID,
                                                                   in: landingZone.behindRange)
            warmAhead = TransportController.shared.warmFrameCount(for: clipID,
                                                                  in: landingZone.aheadRange)

            ReverseScrubDiagnostics.shared.logReverseLandingZone(tNow: tNow,
                                                                 tPred: landingZone.tPred,
                                                                 behindRange: landingZone.behindRange,
                                                                 aheadRange: landingZone.aheadRange,
                                                                 warmBehind: warmBehind,
                                                                 warmAhead: warmAhead)
        }

        if let landingZone,
           warmBehind == 0,
           warmAhead == 0 {
            if coldResetPending.insert(clipID).inserted {
                let resetTarget = landingZone.tPred
                let formattedTarget = String(format: "%.3f", resetTarget)
                print("[COLD_RESET_TRIGGER] clip=\(clipID.uuidString.prefix(8)) target=\(formattedTarget)")
                if let manager = gopManagers[clipID] {
                    await manager.cancelJob()
                }
                await admissionController.forceReleaseForClip(clipID, reason: "cold-reset")
                await decoder.resetForTimelineJump(targetTime: resetTarget)
            }
        } else if warmBehind > 0 || warmAhead > 0 {
            coldResetPending.remove(clipID)
        }

        let requiredBehind = landingZone.map { max($0.windowFrames, config.reverseLZFrames) } ?? config.reverseLZFrames
        let recentDelta = lastDecodeDelta ?? 0
        let severeDelta = abs(recentDelta) > frameDuration * 0.75
        // Reverse-scrub safety net: trigger immediate decodes when the warm buffer runs dry.
        let bypassDebounce = shouldBypassReverseDebounce(direction: direction,
                                                         warmBehind: warmBehind,
                                                         requiredBehind: requiredBehind,
                                                         severeDelta: severeDelta,
                                                         repairMode: landingZone?.repairMode ?? false)

        if ReverseScrubDiagnostics.shared.isEnabled,
           direction == .reverse,
           let landingZone,
           warmBehind < requiredBehind {
            let warmTimes = TransportController.shared.warmFrameTimes(for: clipID,
                                                                      in: landingZone.behindRange,
                                                                      limit: 12)
            ReverseScrubDiagnostics.shared.logWarmSequence(clipID: clipID,
                                                           targetPTS: landingZone.tPred,
                                                           actualPTS: nil,
                                                           warmTimes: warmTimes,
                                                           label: "pre-decode")
        }

        if let lastStart = lastDecodeStartTime[clipID] {
            let timeSinceLastDecode = now - lastStart
            if timeSinceLastDecode < minDecodeInterval {
                if bypassDebounce {
                    print("[DEBOUNCE_BYPASS] clipID=\(clipID.uuidString.prefix(8)) timeSince=\(String(format: "%.1f", timeSinceLastDecode * 1000))ms min=\(String(format: "%.1f", minDecodeInterval * 1000))ms warmBehind=\(warmBehind) required=\(requiredBehind) severe=\(severeDelta) repair=\(landingZone?.repairMode ?? false)")
                } else {
                    print("[DEBOUNCE_SKIP] clipID=\(clipID.uuidString.prefix(8)) timeSince=\(String(format: "%.1f", timeSinceLastDecode * 1000))ms min=\(String(format: "%.1f", minDecodeInterval * 1000))ms")
                    return
                }
            }
        }
        lastDecodeStartTime[clipID] = now

        // SELECTIVE CANCELLATION: Only cancel for specific critical cases
        // DO NOT cancel during normal scrubbing - let tasks complete naturally
        // Cancellation happens only in:
        // 1. Asset switch (original↔proxy) - handled in prepareSource()
        // 2. Cut-edge escalation / hard re-anchor - handled in prepareSource()
        // 3. Deadline lock/stop (exact-frame) - handled in deadlineDecodeForClip()
        // 4. Session errors (-12785/-12909) - handled in error recovery
        // await cancelInflightDecodes(for: clipID)  // REMOVED - causes race condition!

        let idleDuration = now - lastIdleTime
        let isStop = idleDuration >= stopIdleThreshold

        let targets = makeDecodeTargets(clipID: clipID,
                                        tNow: tNow,
                                        tPred: tPred,
                                        direction: direction,
                                        landingZone: landingZone,
                                        frameDuration: frameDuration,
                                        warmBehindCount: warmBehind,
                                        warmAheadCount: warmAhead,
                                        velocityFPS: velocityFPS,
                                        proxyOverrideActive: overrideActive)
        guard !targets.isEmpty else {
            print("[NO_TARGETS] clipID=\(clipID.uuidString.prefix(8))")
            return
        }
        print("[HAS_TARGETS] clipID=\(clipID.uuidString.prefix(8)) count=\(targets.count)")

        // PARALLEL TARGET PROCESSING - Fire and forget for responsiveness
        // Don't wait for tasks to complete - let them run in background
        for target in targets {
            print("[TARGET_LOOP] clipID=\(clipID.uuidString.prefix(8)) pts=\(target.pts) reason=\(target.reason)")
            
            // Capture values for the task
            let capturedWarmBehind = warmBehind
            let capturedRequiredBehind = requiredBehind
            // Start each target in a separate task (fire and forget)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                
                // Check for cancellation at start
                try? Task.checkCancellation()
                
                let isReverse = direction == .reverse
                let urgentReason = target.reason == "pred" ||
                    target.reason == "now" ||
                    target.reason == "lz" ||
                    target.reason == "fallback_prev" ||
                    target.reason == "repairBehind"
                let hasNoSuccess = self.decodeSuccessCount[clipID, default: 0] == 0
                let warmShort = capturedWarmBehind < capturedRequiredBehind
                let needsImmediate = isReverse && urgentReason && (warmShort || hasNoSuccess)
                if needsImmediate {
                    await ReverseScrubDiagnostics.shared.logImmediateAdmission(clipID: clipID,
                                                                         reason: target.reason,
                                                                         warmBehind: capturedWarmBehind,
                                                                         requiredBehind: capturedRequiredBehind,
                                                                         velocityFPS: velocityFPS)
                }
                let targetAbsMs = Int64((target.pts * 1000.0).rounded())
                print("[BEFORE_PREPARE_SOURCE] clipID=\(clipID.uuidString.prefix(8)) targetMs=\(targetAbsMs)")
                let sourceReady = await self.prepareSource(clipID: clipID,
                                                       decoder: decoder,
                                                       targetAbsMs: targetAbsMs,
                                                       reason: target.reason,
                                                       isDeadline: false,
                                                       cancelOthers: false)  // Changed to false to allow parallel processing
                print("[AFTER_PREPARE_SOURCE] clipID=\(clipID.uuidString.prefix(8)) targetMs=\(targetAbsMs) sourceReady=\(sourceReady) reason=\(target.reason)")
                guard sourceReady else {
                    print("❌ [SOURCE_NOT_READY] clipID=\(clipID.uuidString.prefix(8)) pts=\(target.pts) reason=\(target.reason)")
                    return
                }
                if direction == .reverse {
                    let reverseActive = await self.admissionController.reverseInflightCount(for: clipID)

                    // CRITICAL FIX: Detect stuck tasks and force cleanup
                    // When active>=maxInflight AND warmBehind=0, tasks are stuck (hung decode calls)
                    // This happens when VT-12785 errors cause decoder.decodeFrameSimple() to hang
                    // Without cleanup, the system deadlocks permanently
                    if reverseActive >= self.config.maxInFlightPerClip {
                        if warmBehind == 0 && reverseActive >= self.config.maxInFlightPerClip {
                            // RACE CONDITION FIX: Only one thread should perform stuck detection
                            let now = CFAbsoluteTimeGetCurrent()
                            let lastDetection = self.lastStuckDetectionTime[clipID] ?? 0
                            let timeSinceLastDetection = now - lastDetection

                            if !self.stuckDetectionInProgress.contains(clipID) && timeSinceLastDetection > 0.5 {
                                self.stuckDetectionInProgress.insert(clipID)
                                self.lastStuckDetectionTime[clipID] = now

                                print("🔴 [STUCK_TASKS_DETECTED] clipID=\(clipID.uuidString.prefix(8)) active=\(reverseActive) warm=0 - FORCE CLEANUP")
                                await self.admissionController.forceReleaseForClip(clipID, reason: "stuck-detection")

                                // ENHANCED FIX: Complete VT session rebuild, not just reader
                                // The VT decoder session itself may be corrupted, not just the reader
                                print("🔴 [VT_SESSION_REBUILD] clipID=\(clipID.uuidString.prefix(8)) - COMPLETE DECODER RESET")
                                await decoder.forceCompleteReset(targetTime: tPred)

                                if let manager = self.gopManagers[clipID] {
                                    await manager.cancelJob()
                                }

                                // Small delay to let cleanup complete before removing flag
                                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                                self.stuckDetectionInProgress.remove(clipID)
                            } else {
                                print("[REVERSE_INFLIGHT_LIMIT] clipID=\(clipID.uuidString.prefix(8)) active=\(reverseActive) max=\(self.config.maxInFlightPerClip) pending_cleanup=\(self.stuckDetectionInProgress.contains(clipID))")
                                return
                            }
                        } else {
                            print("[REVERSE_INFLIGHT_LIMIT] clipID=\(clipID.uuidString.prefix(8)) active=\(reverseActive) max=\(self.config.maxInFlightPerClip)")
                            return
                        }
                    }
                }
                if self.flags.admissionControl {
                    let admission = await self.admissionController.checkAdmission(clipID: clipID,
                                                                             direction: direction,
                                                                             velocityFPS: velocityFPS,
                                                                             isStop: isStop,
                                                                             purpose: target.reason,
                                                                             needsImmediate: needsImmediate,
                                                                             warmBehind: capturedWarmBehind,
                                                                             warmRequired: capturedRequiredBehind)
                    if !admission.admitted {
                        print("❌ [ADMISSION_DENIED] clipID=\(clipID.uuidString.prefix(8)) reason=\(admission.reason) purpose=\(target.reason)")
                        if admission.reason == "clip_limit" && !self.config.admissionNeverCancelRunning {
                            await self.admissionController.forceReleaseForClip(clipID, reason: "clip_limit_guard")
                        }
                        return
                    } else {
                        print("[ADMISSION_OK] clipID=\(clipID.uuidString.prefix(8)) purpose=\(target.reason)")
                    }
                }

                print("[BEFORE_GOP_DECIDE] clipID=\(clipID.uuidString.prefix(8)) target.pts=\(target.pts)")
                let gopKey = self.computeGOPKey(for: target.pts, frameDuration: frameDuration)
                let decision = await gopManager.decide(newGOPKey: gopKey, newTarget: target.pts)
                print("[GOP_DECISION] clipID=\(clipID.uuidString.prefix(8)) decision=\(decision) reason=\(target.reason)")

                var shouldStartJob = false
                switch decision {
                case .reuse(let retarget):
                    if retarget {
                        // CRITICAL FIX: Always restart on retarget to avoid stale targets
                        // Stale targets cause reader to decode wrong frames (future frames during reverse scrub)
                        // Cancel old task and start fresh with current target
                        print("[GOP_RETARGET_RESTART] clipID=\(clipID.uuidString.prefix(8)) newTarget=\(target.pts) reason=\(target.reason)")
                        await gopManager.cancelJob()
                        shouldStartJob = true
                    } else {
                        print("[GOP_REUSE_HOLD] clipID=\(clipID.uuidString.prefix(8))")
                        return
                    }
                case .cancel:
                    print("[GOP_CANCEL] clipID=\(clipID.uuidString.prefix(8))")
                    await gopManager.cancelJob()
                    shouldStartJob = true
                case .start:
                    print("[GOP_START] clipID=\(clipID.uuidString.prefix(8))")
                    shouldStartJob = true
                }

                guard shouldStartJob else { return }

                await gopManager.reserveJob(gopKey: gopKey, targetPTS: target.pts)
                await self.admissionController.markStarted(clipID: clipID, direction: direction)
                let task = self.scheduleDecodeTask(clipID: clipID, direction: direction) { [weak self] in
                    guard let self else { return }
                    await self.performDecode(clipID: clipID,
                                             decoder: decoder,
                                             targetPTS: target.pts,
                                             storeInPrimary: target.storeInPrimary,
                                             reason: target.reason,
                                             gopManager: gopManager,
                                             frameDuration: frameDuration,
                                             direction: direction,
                                             velocityFPS: velocityFPS,
                                             tPred: tPred)
                }
                await gopManager.registerJob(gopKey: gopKey, targetPTS: target.pts, task: task)
                
                // Fire and forget - don't wait for completion
                // This allows scrubbing to remain responsive
            }
        }
    }

    private func shouldBypassReverseDebounce(direction: ScrubCoordinator.ScrubDirection,
                                              warmBehind: Int,
                                              requiredBehind: Int,
                                              severeDelta: Bool,
                                              repairMode: Bool) -> Bool {
        guard direction == .reverse else { return false }
        if repairMode { return true }
        if severeDelta { return true }
        if warmBehind == 0 { return true }
        return warmBehind < requiredBehind
    }

    private func resetReverseFailure(for clipID: UUID) {
        reverseFailureStreak[clipID] = 0
        reverseRecoveryAnchor[clipID] = nil
    }

    private func registerReverseFailure(clipID: UUID,
                                        decoder: EnhancedScrubDecoder,
                                        failingPTS: TimeInterval,
                                        frameDuration: Double,
                                        velocityFPS: Double,
                                        gopManager: GOPCoalescingManager,
                                        reason: String) async {
        guard StableScrubMode.enabled else { return }
        let current = reverseFailureStreak[clipID] ?? 0
        let next = current + 1
        reverseFailureStreak[clipID] = next
        let threshold = max(1, config.reverseFailureRecoveryThreshold)
        guard next >= threshold else { return }

        reverseFailureStreak[clipID] = 0
        let timelineTime = TransportController.shared.latchedTime
        let frameSafe = max(frameDuration, 1e-4)
        let baseBackoff = max(config.reverseFailureBackoff,
                              frameSafe * Double(max(config.reverseLZFrames, 2)))
        let backoff = min(baseBackoff, config.reverseFailureMaxBackoff)
        let fallbackPTS = max(min(failingPTS - backoff, timelineTime - frameSafe), 0)
        if ScrubFeatureFlags.shared.telemetryEnabled {
            let clipKey = clipID.uuidString.prefix(8)
            print("[REVERSE_RECOVERY] clip=\(clipKey) failures=\(next) reason=\(reason) fallback=\(String(format: "%.3f", fallbackPTS)) original=\(String(format: "%.3f", failingPTS)) backoff=\(String(format: "%.3f", backoff))")
        }

        reverseRecoveryAnchor[clipID] = fallbackPTS
        let fallbackIndex = max(Int((fallbackPTS / frameSafe).rounded(.down)), 0)
        reverseFrameCursor[clipID] = fallbackIndex
        lastRequestedIndex[clipID] = fallbackIndex
        lastDirectionChangeTime[clipID] = CFAbsoluteTimeGetCurrent()

        await gopManager.cancelJob()
        coldResetPending.insert(clipID)
        await admissionController.forceReleaseForClip(clipID, reason: "reverse-recovery")
        await decoder.forceCompleteReset(targetTime: fallbackPTS)

        let repairDelta = failingPTS - fallbackPTS
        if repairDelta > frameSafe * 0.5 {
            scheduleRepairDecodes(clipID: clipID,
                                  decoder: decoder,
                                  desiredPTS: fallbackPTS,
                                  direction: .reverse,
                                  frameDuration: frameDuration,
                                  velocityFPS: velocityFPS,
                                  delta: repairDelta,
                                  forceRetarget: true)
        }
    }

    private func performDecode(clipID: UUID,
                                decoder: EnhancedScrubDecoder,
                                targetPTS: TimeInterval,
                                storeInPrimary: Bool,
                                reason: String,
                                gopManager: GOPCoalescingManager,
                                frameDuration: Double,
                                direction: ScrubCoordinator.ScrubDirection,
                                velocityFPS: Double,
                                tPred: TimeInterval) async {
        var completedSuccessfully = false

        do {
            print("[DECODE_START] clip=\(clipID.uuidString.prefix(8)) target=\(String(format: "%.3f", targetPTS)) reason=\(reason)")

            let decodeStart = CFAbsoluteTimeGetCurrent()

            // CRITICAL FIX: Add timeout to prevent hanging decode calls
            // VT-12785 errors can cause decoder.decodeFrameSimple() to hang indefinitely
            // Without timeout, tasks stay in "inflight" state forever, blocking all future decodes
            let timeout: TimeInterval = direction == .reverse ? 2.0 : 5.0  // Aggressive timeout for reverse scrubbing
            let (pixelBuffer, pts) = try await withThrowingTaskGroup(of: (CVPixelBuffer, TimeInterval).self) { group in
                group.addTask {
                    try await decoder.decodeFrameSimple(at: targetPTS,
                                                       tPred: tPred,
                                                       direction: direction)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CancellationError()
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }

            let decodeDuration = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

            // DIAGNOSTIC: Log pixel buffer details
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("[DECODE_SUCCESS] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) format=\(format) size=\(width)x\(height) reason=\(reason) duration=\(String(format: "%.1f", decodeDuration))ms")

            let delta = targetPTS - pts
            recentDecodeDelta[clipID] = delta
            decoderErrorStreak[clipID] = 0
            clearProxyOverride(for: clipID)
            let severeDelta = abs(delta) > frameDuration * 0.75
            let timelineTime = TransportController.shared.latchedTime
            let displayLead = pts - timelineTime
            let futureLeadCap = config.reverseFutureLeadCap
            let frameDurationSafe = max(frameDuration, 1e-4)
            var shouldStorePrimary = storeInPrimary && abs(delta) <= frameDuration * 0.75
            var futureFrameDetected = false
            if direction == .reverse && displayLead > futureLeadCap {
                futureFrameDetected = true
                shouldStorePrimary = false
                if ScrubFeatureFlags.shared.telemetryEnabled {
                    print("[FUTURE_FRAME_DETECT] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) lead=\(String(format: "%.3f", displayLead)) cap=\(String(format: "%.3f", futureLeadCap)) reason=\(reason)")
                }
            }
            ReverseScrubDiagnostics.shared.logStoreDecision(clipID: clipID,
                                                            reason: reason,
                                                            targetPTS: targetPTS,
                                                            actualPTS: pts,
                                                            storeInPrimary: shouldStorePrimary,
                                                            deltaMS: delta * 1000.0)
            if delta > frameDuration * 3.0 {
                print("⚠️ [IntegratedScrubPipeline] Discarding stale frame clip=\(clipID) target=\(String(format: "%.3f", targetPTS)) actual=\(String(format: "%.3f", pts)) Δ=\(String(format: "%.3f", delta))s reason=\(reason)")
                scheduleRepairDecodes(clipID: clipID,
                                      decoder: decoder,
                                      desiredPTS: targetPTS,
                                      direction: direction,
                                      frameDuration: frameDuration,
                                      velocityFPS: velocityFPS,
                                      delta: delta,
                                      forceRetarget: true)
            } else {
                if direction == .reverse && !futureFrameDetected {
                    commitReverseCursor(for: clipID)
                }

                if futureFrameDetected {
                    if ScrubFeatureFlags.shared.telemetryEnabled {
                        print("[FUTURE_FRAME_DROP] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) lead=\(String(format: "%.3f", displayLead))")
                    }
                } else if shouldStorePrimary {
                    print("[CACHE_FRAME] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) primary=true")
                    TransportController.shared.cacheFrame(pixelBuffer,
                                                          clipID: clipID,
                                                          presentationTime: pts,
                                                          version: currentEpoch,
                                                          origin: .scrub,
                                                          storeInPrimary: true)
                    decodeSuccessCount[clipID, default: 0] += 1
                } else if !severeDelta {
                    print("[CACHE_FRAME] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) primary=false")
                    TransportController.shared.cacheFrame(pixelBuffer,
                                                          clipID: clipID,
                                                          presentationTime: pts,
                                                          version: currentEpoch,
                                                          origin: .scrub,
                                                          storeInPrimary: false)
                    decodeSuccessCount[clipID, default: 0] += 1
                }
                if severeDelta {
                    scheduleRepairDecodes(clipID: clipID,
                                          decoder: decoder,
                                          desiredPTS: targetPTS,
                                          direction: direction,
                                          frameDuration: frameDuration,
                                          velocityFPS: velocityFPS,
                                          delta: delta,
                                          forceRetarget: true)
                } else if abs(delta) > frameDuration * 1.5 {
                    print("⚠️ [IntegratedScrubPipeline] Large NP delta clip=\(clipID) target=\(String(format: "%.3f", targetPTS)) actual=\(String(format: "%.3f", pts)) Δ=\(String(format: "%.3f", delta))s reason=\(reason)")
                }

                if !severeDelta && abs(delta) > frameDuration * 1.5 && reason != "repair" {
                    let repairBase = direction == .reverse ? targetPTS : pts
                    scheduleRepairDecodes(clipID: clipID,
                                          decoder: decoder,
                                          desiredPTS: repairBase,
                                          direction: direction,
                                          frameDuration: frameDuration,
                                          velocityFPS: velocityFPS,
                                          delta: delta,
                                          forceRetarget: true)
                }

                if futureFrameDetected {
                    let timelineIndex = max(Int((timelineTime / frameDurationSafe).rounded(.down)), 0)
                    reverseFrameCursor[clipID] = timelineIndex
                    lastRequestedIndex[clipID] = timelineIndex
                    lastDirectionChangeTime[clipID] = CFAbsoluteTimeGetCurrent()

                    let backoff = max(config.reverseFutureBackoff, frameDurationSafe * 4.0)
                    let baseRepairPTS = max(min(targetPTS - backoff, timelineTime - frameDurationSafe), 0)
                    let repairPTS = min(baseRepairPTS, timelineTime)
                    let repairDelta = targetPTS - repairPTS
                    let repairIndex = max(Int((repairPTS / frameDurationSafe).rounded(.down)), 0)
                    reverseFrameCursor[clipID] = repairIndex
                    lastRequestedIndex[clipID] = repairIndex
                    await decoder.resetForTimelineJump(targetTime: repairPTS)
                    await gopManager.cancelJob()
                    scheduleRepairDecodes(clipID: clipID,
                                          decoder: decoder,
                                          desiredPTS: repairPTS,
                                          direction: direction,
                                          frameDuration: frameDuration,
                                          velocityFPS: velocityFPS,
                                          delta: repairDelta,
                                          forceRetarget: true)
                }

                if ReverseScrubDiagnostics.shared.isEnabled && direction == .reverse {
                    let span = max(frameDuration * 12.0, 0.5)
                    let lowerBound = max(min(targetPTS, tPred) - span, 0)
                    let upperBound = max(targetPTS, tPred) + frameDuration * 2.0
                    let warmRange = lowerBound...upperBound
                    let warmTimes = TransportController.shared.warmFrameTimes(for: clipID,
                                                                              in: warmRange,
                                                                              limit: 12)
                    ReverseScrubDiagnostics.shared.logWarmSequence(clipID: clipID,
                                                                   targetPTS: targetPTS,
                                                                   actualPTS: pts,
                                                                   warmTimes: warmTimes,
                                                                   label: "post-cache")
                }

                if flags.telemetryEnabled {
                    ScrubTelemetry.shared.logDecode(ScrubTelemetry.DecodeLog(timestamp: CFAbsoluteTimeGetCurrent(),
                                                                            pts: pts,
                                                                            durationMS: decodeDuration,
                                                                            reason: reason,
                                                                             epoch: currentEpoch))
                }

                if flags.verboseLogging {
                    print("[IntegratedScrubPipeline] Decoded \(reason) frame at \(String(format: "%.3f", pts))s in \(String(format: "%.1f", decodeDuration))ms (storePrimary=\(shouldStorePrimary))")
                }
            }
            resetReverseFailure(for: clipID)
            completedSuccessfully = true
        } catch is CancellationError {
            print("❌ [DECODE_CANCELLED] clip=\(clipID.uuidString.prefix(8)) target=\(String(format: "%.3f", targetPTS)) reason=\(reason)")
            if stableReverse {
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logWatchdog(clipID: clipID,
                                                              reason: "timeout")
                }
            }
            if direction == .reverse {
                await registerReverseFailure(clipID: clipID,
                                             decoder: decoder,
                                             failingPTS: targetPTS,
                                             frameDuration: frameDuration,
                                             velocityFPS: velocityFPS,
                                             gopManager: gopManager,
                                             reason: reason)
            }
        } catch {
            print("❌ [DECODE_ERROR] clip=\(clipID.uuidString.prefix(8)) target=\(String(format: "%.3f", targetPTS)) reason=\(reason) error=\(error)")
            if flags.telemetryEnabled {
                print("[IntegratedScrubPipeline] Decode failed for clip \(clipID): \(error)")
            }

            // CRITICAL FIX: Aggressive -12785 error handling
            // VT error -12785 (kVTVideoDecoderBadDataErr) means corrupted/bad data in reader
            // Instead of retrying with same reader, immediately rebuild reader to recover
            let nsError = error as NSError
            let is12785Error = nsError.code == -12785 ||
                              (nsError.domain == "com.apple.videotoolbox" && nsError.code == -12785) ||
                              nsError.localizedDescription.contains("12785")

            if is12785Error {
                print("🔴 [VT_12785_AGGRESSIVE_RECOVERY] clip=\(clipID.uuidString.prefix(8)) - COMPLETE RESET WITH IDR FALLBACK")

                // ENHANCED: Track -12785 errors per clip to determine if we need IDR fallback
                let errorCount = self.decoderErrorStreak[clipID, default: 0] + 1
                self.decoderErrorStreak[clipID] = errorCount
                if errorCount >= config.reverseProxyErrorThreshold {
                    let targetMs = Int64((targetPTS * 1000.0).rounded())
                    await self.activateProxyOverride(clipID: clipID, targetMs: targetMs, reason: "vt12785")
                }

                if errorCount >= 3 {
                    // After 3 consecutive -12785 errors, jump to different position
                    // This helps escape from corrupted GOP/IDR sequences
                    print("🔴 [VT_12785_IDR_FALLBACK] clip=\(clipID.uuidString.prefix(8)) errors=\(Int(errorCount)) - JUMPING TO DIFFERENT TIME")
                    let jumpOffset = frameDuration * 10.0  // Jump 10 frames back
                    let newTarget = max(targetPTS - jumpOffset, 0)
                    await decoder.forceCompleteReset(targetTime: newTarget)
                    self.decoderErrorStreak[clipID] = 0  // Reset error count
                } else {
                    // First few errors: just rebuild reader at same position
                    await decoder.resetForTimelineJump(targetTime: tPred)
                }

                await gopManager.cancelJob()
                // Give decoder time to rebuild before retry
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }

            if ReverseScrubDiagnostics.shared.isEnabled {
                let context = "\(nsError.domain)#\(reason)"
                ReverseScrubDiagnostics.shared.logDecoderError(clipID: clipID,
                                                               code: nsError.code,
                                                               stage: "decode",
                                                               context: context)
                if direction == .reverse {
                    let span = max(frameDuration * 12.0, 0.5)
                    let lowerBound = max(min(targetPTS, tPred) - span, 0)
                    let upperBound = max(targetPTS, tPred) + frameDuration * 2.0
                    let warmRange = lowerBound...upperBound
                    let warmTimes = TransportController.shared.warmFrameTimes(for: clipID,
                                                                              in: warmRange,
                                                                              limit: 12)
                    ReverseScrubDiagnostics.shared.logWarmSequence(clipID: clipID,
                                                                   targetPTS: targetPTS,
                                                                   actualPTS: nil,
                                                                   warmTimes: warmTimes,
                                                                   label: "decode-error")
                }
            }
            scheduleRepairDecodes(clipID: clipID,
                                  decoder: decoder,
                                  desiredPTS: targetPTS,
                                  direction: direction,
                                  frameDuration: frameDuration,
                                  velocityFPS: velocityFPS,
                                  delta: frameDuration,
                                  forceRetarget: true)
            if direction == .reverse {
                await registerReverseFailure(clipID: clipID,
                                             decoder: decoder,
                                             failingPTS: targetPTS,
                                             frameDuration: frameDuration,
                                             velocityFPS: velocityFPS,
                                             gopManager: gopManager,
                                             reason: is12785Error ? "vt12785" : reason)
            }
        }
        await gopManager.clearJob()
        if completedSuccessfully {
            await admissionController.markCompleted(clipID: clipID, direction: direction)
        } else {
            await admissionController.onDecodeFailureOrTimeout(clipID: clipID, direction: direction)
        }
    }
    
    private func deadlineDecodeForClip(clipID: UUID,
                                        decoder: EnhancedScrubDecoder,
                                        tFinal: TimeInterval) async {
        let direction: ScrubCoordinator.ScrubDirection = .reverse
        await cancelInflightDecodes(for: clipID)
        let admission = await admissionController.checkAdmission(clipID: clipID,
                                                                  direction: direction,
                                                                  velocityFPS: 0,
                                                                  isStop: true,
                                                                  purpose: "deadline",
                                                                  needsImmediate: true,
                                                                  warmBehind: 0,
                                                                  warmRequired: config.reverseLZFrames)
        guard admission.admitted else {
            if flags.telemetryEnabled {
                print("[IntegratedScrubPipeline] Deadline decode skipped clip=\(clipID) reason=\(admission.reason)")
            }
            return
        }

        await admissionController.markStarted(clipID: clipID, direction: direction, isDeadline: true)
        let targetAbsMs = Int64((tFinal * 1000.0).rounded())
        let prepared = await prepareSource(clipID: clipID,
                                            decoder: decoder,
                                            targetAbsMs: targetAbsMs,
                                            reason: "deadline",
                                            isDeadline: true,
                                            cancelOthers: true)
        guard prepared else {
            await admissionController.onDecodeFailureOrTimeout(clipID: clipID, direction: direction)
            return
        }
        await decoder.prepareForDeadline(at: tFinal)
        var completed = false
        do {
                let (pixelBuffer, pts) = try await decoder.decodeFrameSimple(at: tFinal,
                                                                            tPred: tFinal,
                                                                            direction: direction,
                                                                            deadline: true)
            TransportController.shared.cacheFrame(pixelBuffer,
                                                   clipID: clipID,
                                                   presentationTime: pts,
                                                   version: currentEpoch,
                                                   origin: .scrub,
                                                   storeInPrimary: true)
            decodeSuccessCount[clipID, default: 0] += 1
            completed = true
        } catch EnhancedScrubDecoder.DecodeFlowError.skippedDeadline {
            if flags.verboseLogging {
                print("[IntegratedScrubPipeline] Deadline decode skipped duplicate signature clip=\(clipID)")
            }
            await admissionController.markCompleted(clipID: clipID, direction: direction)
            return
        } catch {
            if flags.verboseLogging {
                print("[IntegratedScrubPipeline] Deadline decode failed for clip \(clipID): \(error)")
            }
            let absMs = Int64((tFinal * 1000.0).rounded())
            if let asset = clipSources[clipID]?.asset {
                await proxyManager.noteDeadlineFailure(clipID: clipID, targetAbsMs: absMs, asset: asset)
            }
        }

        if completed {
            await admissionController.markCompleted(clipID: clipID, direction: direction)
        } else {
            await admissionController.onDecodeFailureOrTimeout(clipID: clipID, direction: direction)
        }
    }

    private func cancelInflightDecodes(for clipID: UUID) async {
        // Cancel all active decode tasks
        if let tasks = activeDecodeTasks[clipID] {
            for (_, task) in tasks {
                if !task.isCancelled {
                    print("[CANCEL_INFLIGHT] clip=\(clipID.uuidString.prefix(8))")
                    task.cancel()
                }
            }
            activeDecodeTasks[clipID] = nil
        }
        
        if let manager = gopManagers[clipID] {
            await manager.cancelJob()
        }
        if let taskMap = repairTasks[clipID] {
            for task in taskMap.values {
                task.cancel()
        }
        repairTasks[clipID] = nil
        }
        repairInflight[clipID] = nil
        reverseFailureStreak[clipID] = 0
        reverseRecoveryAnchor[clipID] = nil
        reverseFrameCursor[clipID] = nil
        recentDecodeDelta.removeValue(forKey: clipID)
        decoderErrorStreak.removeValue(forKey: clipID)
        sourceOverrides.removeValue(forKey: clipID)
        await admissionController.onDecodeFailureOrTimeout(clipID: clipID, direction: .reverse)
        await admissionController.forceReleaseForClip(clipID, reason: "cancel")
    }

    private func prepareSource(clipID: UUID,
                                decoder: EnhancedScrubDecoder,
                                targetAbsMs: Int64,
                                reason: String,
                                isDeadline: Bool,
                                cancelOthers: Bool = false) async -> Bool {
        print("[PREPARE_SOURCE_ENTER] clipID=\(clipID.uuidString.prefix(8)) targetMs=\(targetAbsMs) reason=\(reason)")
        guard let source = clipSources[clipID] else {
            print("[PREPARE_SOURCE_EXIT] clipID=\(clipID.uuidString.prefix(8)) reason=no-source result=true")
            return true
        }

        if let lateTrigger = await proxyManager.consumeLateFrameTrigger(for: clipID) {
            await proxyManager.ensureSpotProxy(clipID: clipID,
                                               asset: source.asset,
                                               aroundAbsMs: lateTrigger,
                                               spanMs: 4000,
                                               reason: "late-frames",
                                               context: isDeadline ? "deadline-late" : "late-frame")
        }

        let now = CFAbsoluteTimeGetCurrent()
        let stickyHoldActive = (stickyProxyHoldUntil[clipID] ?? 0) > now
        let currentSource = activeSources[clipID] ?? .original
        var overrideMode: SourceOverrideMode?

        if var overrideState = sourceOverrides[clipID] {
            if overrideState.expiry <= now {
                sourceOverrides.removeValue(forKey: clipID)
            } else {
                overrideMode = overrideState.mode
                if overrideState.mode == .preferProxy && now - overrideState.lastRequest >= 0.5 {
                    overrideState.lastRequest = now
                    sourceOverrides[clipID] = overrideState
                    await proxyManager.ensureSpotProxy(clipID: clipID,
                                                       asset: source.asset,
                                                       aroundAbsMs: targetAbsMs,
                                                       spanMs: 4000,
                                                       reason: "override",
                                                       context: "prepare")
                } else {
                    sourceOverrides[clipID] = overrideState
                }
            }
        }

        var decision = await proxyManager.decision(for: clipID, absMs: targetAbsMs)

        if stickyHoldActive,
           case .proxy(let activeZone) = currentSource,
           case .original = decision,
           let info = activeProxyInfo[clipID] {
            decision = .proxy(info: info)
        }

        var desiredSource: DecodeSource = .original
        var desiredInfo: SpotProxyManager.ProxyInfo?
        var debugNotes: [String] = []

        switch decision {
        case .original:
            desiredSource = .original
        case .proxy(let info):
            desiredSource = .proxy(info.zoneID)
            desiredInfo = info
        }

        if overrideMode == .preferProxy {
            debugNotes.append("override-proxy")
            if case .original = decision, let info = activeProxyInfo[clipID] {
                desiredSource = .proxy(info.zoneID)
                desiredInfo = info
                debugNotes.append("override-active-proxy")
            } else if case .original = decision {
                debugNotes.append("override-waiting")
                if ScrubFeatureFlags.shared.verboseLogging {
                    print("[PROXY_OVERRIDE_WAIT] clip=\(clipID.uuidString.prefix(8)) target_ms=\(targetAbsMs) mode=prefProxy")
                }
            }
        }

        if case .proxy = desiredSource, desiredInfo == nil {
            debugNotes.append("proxy-info-missing")
            desiredSource = .original
        }

        func describeSource(_ source: DecodeSource, info: SpotProxyManager.ProxyInfo?) -> String {
            switch source {
            case .original:
                return "original"
            case .proxy(let zoneID):
                let zoneString = zoneID.uuidString.prefix(8)
                let context = info?.context ?? "-"
                return "proxy:\(zoneString):\(context)"
            }
        }

        func emitPrepareLog(ready: Bool, extraNote: String? = nil) {
            var notes = debugNotes
            if let extraNote = extraNote {
                notes.append(extraNote)
            }
            let noteText = notes.isEmpty ? "-" : notes.joined(separator: "+")
            let message = "[PREPARE_SOURCE] clip=\(clipID.uuidString.prefix(8)) target_ms=\(targetAbsMs) reason=\(reason) desired=\(describeSource(desiredSource, info: desiredInfo)) switching=\(desiredSource != currentSource ? "t" : "f") ready=\(ready ? "t" : "f") note=\(noteText)"
            print(message)
            if ReverseScrubDiagnostics.shared.isEnabled {
                ReverseScrubDiagnostics.shared.logPrepareSource(clipID: clipID,
                                                                targetMs: targetAbsMs,
                                                                reason: reason,
                                                                desiredSource: describeSource(desiredSource, info: desiredInfo),
                                                                switching: desiredSource != currentSource,
                                                                ready: ready,
                                                                note: noteText)
            }
        }

        // CRITICAL FIX: Only wait for proxy during deadline (exact frame)
        // During scrubbing: use original immediately for fast decodes!
        if case .original = desiredSource, isDeadline {  // Changed: only for deadline!
            let avoidOriginal = await decoder.shouldAvoidOriginal()
            if avoidOriginal {
                print("❌ [SOURCE_AVOID_ORIGINAL] clip=\(clipID.uuidString.prefix(8)) t=\(targetAbsMs) reason=\(reason) - waiting for proxy (deadline)")
                emitPrepareLog(ready: false, extraNote: "avoid-original")
                return false
            }
        }
        // During scrubbing (!isDeadline): skip check, use original immediately!

        let switching = desiredSource != currentSource
        if switching {
            debugNotes.append("switch")
            await cancelInflightDecodes(for: clipID)
            await admissionController.forceReleaseForClip(clipID, reason: "switch")
        } else {
            debugNotes.append("reuse")
            if cancelOthers && isDeadline {
                await cancelInflightDecodes(for: clipID)
                await admissionController.forceReleaseForClip(clipID, reason: "deadlineswitch")
            }
        }

        let warmSpreadMs: Int64 = {
            switch desiredSource {
            case .proxy:
                return 900
            case .original:
                return 450
            }
        }()

        if !switching {
            if case .proxy(let zoneID) = desiredSource,
               let info = desiredInfo ?? activeProxyInfo[clipID] {
                stickyProxyHoldUntil[clipID] = now + proxyHoldDuration
                activeProxyInfo[clipID] = info
                activeSources[clipID] = .proxy(zoneID)
                // Fire-and-forget warm - don't block on it
                Task { await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs) }
                emitPrepareLog(ready: true, extraNote: "reuse-proxy")
            } else if case .original = desiredSource {
                stickyProxyHoldUntil[clipID] = nil
                activeProxyInfo[clipID] = nil
                activeSources[clipID] = .original
                // Fire-and-forget warm - don't block on it
                Task { await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs) }
                emitPrepareLog(ready: true, extraNote: "reuse-original")
            }
            return true
        }

        switch desiredSource {
        case .original:
            await decoder.useOriginalSource()
            activeSources[clipID] = .original
            activeProxyInfo[clipID] = nil
            stickyProxyHoldUntil[clipID] = nil
            // Fire-and-forget warm - don't block on it
            Task { await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs) }
            emitPrepareLog(ready: true, extraNote: "switch-original")
            return true
        case .proxy(let zoneID):
            guard let info = desiredInfo ?? activeProxyInfo[clipID] else {
                desiredSource = .original
                desiredInfo = nil
                debugNotes.append("proxy-missing-active")
                await decoder.useOriginalSource()
                activeSources[clipID] = .original
                activeProxyInfo[clipID] = nil
                stickyProxyHoldUntil[clipID] = nil
                await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs)
                clearProxyOverride(for: clipID)
                emitPrepareLog(ready: true, extraNote: "fallback-original")
                return true
            }
            let applied = await decoder.useProxySource(info: info)
            if applied {
                activeSources[clipID] = .proxy(zoneID)
                activeProxyInfo[clipID] = info
                stickyProxyHoldUntil[clipID] = now + proxyHoldDuration
                await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs)
                emitPrepareLog(ready: true, extraNote: "switch-proxy")
                return true
            } else {
                desiredSource = .original
                desiredInfo = nil
                debugNotes.append("proxy-apply-failed")
                activeSources[clipID] = .original
                activeProxyInfo[clipID] = nil
                stickyProxyHoldUntil[clipID] = nil
                await decoder.useOriginalSource()
                await decoder.warmRandomAccess(around: targetAbsMs, spreadMs: warmSpreadMs)
                clearProxyOverride(for: clipID)
                emitPrepareLog(ready: true, extraNote: "fallback-original")
                return true
            }
        }
    }

    private func scheduleRepairDecodes(clipID: UUID,
                                       decoder: EnhancedScrubDecoder,
                                       desiredPTS: TimeInterval,
                                       direction: ScrubCoordinator.ScrubDirection,
                                       frameDuration: Double,
                                       velocityFPS: Double,
                                       delta: Double,
                                       forceRetarget: Bool = false) {
        // Allow forced repairs even while scrubbing; otherwise defer until idle to avoid VT contention
        if isActive && !forceRetarget { return }
        
        let frameDurationSafe = max(frameDuration, 1e-4)
        let maxAheadWindow: Double
        if direction == .reverse {
            maxAheadWindow = adaptiveReverseAheadWindow(frameDuration: frameDurationSafe,
                                                        velocityFPS: velocityFPS)
        } else {
            maxAheadWindow = min(frameDurationSafe * 0.5, 0.030)
        }

        let maxDeltaMultiplier = direction == .reverse ? 6.0 : 2.0
        let maxDelta = frameDurationSafe * maxDeltaMultiplier
        let clampedDelta = max(min(delta, maxDelta), -maxDelta)
        let boundedDelta = max(min(clampedDelta, maxAheadWindow), -maxAheadWindow)
        let urgentRepair = abs(delta) > frameDurationSafe * 0.75

        var queued: Set<Int64> = []
        let quantizer = { (time: TimeInterval) -> Int64 in
            let clamped = max(time, 0)
            return Int64((clamped * 1000.0).rounded())
        }

        func queue(_ pts: TimeInterval, force: Bool = false, bypassRate: Bool = false) {
            let key = quantizer(pts)
            guard !queued.contains(key) else { return }
            queued.insert(key)
            enqueueRepairDecode(clipID: clipID,
                                decoder: decoder,
                                targetPTS: max(pts, 0),
                                basePTS: desiredPTS,
                                direction: direction,
                                frameDuration: frameDurationSafe,
                                velocityFPS: velocityFPS,
                                maxAheadWindow: maxAheadWindow,
                                forceRetarget: force,
                                bypassRateGate: bypassRate)
        }

        if abs(boundedDelta) > 1e-5 {
            queue(desiredPTS + boundedDelta, force: forceRetarget, bypassRate: urgentRepair)
        }

        queue(desiredPTS, force: forceRetarget, bypassRate: urgentRepair)

        ReverseScrubDiagnostics.shared.logRepair(errorFrames: delta / frameDurationSafe,
                                                 offsetSeconds: boundedDelta,
                                                 retarget: false)
    }

    private func enqueueRepairDecode(clipID: UUID,
                                     decoder: EnhancedScrubDecoder,
                                     targetPTS: TimeInterval,
                                     basePTS: TimeInterval,
                                     direction: ScrubCoordinator.ScrubDirection,
                                     frameDuration: Double,
                                     velocityFPS: Double,
                                     maxAheadWindow: Double,
                                     forceRetarget: Bool = false,
                                     bypassRateGate: Bool = false) {
        guard targetPTS.isFinite else { return }

        let quantized = Int64((targetPTS * 1000.0).rounded())
        var inflight = repairInflight[clipID] ?? Set<Int64>()
        if inflight.contains(quantized) {
            return
        }
        if inflight.count >= 1 && !forceRetarget {
            return
        }
        inflight.insert(quantized)
        repairInflight[clipID] = inflight

        let admissionEnabled = flags.admissionControl
        let verboseLogging = flags.telemetryEnabled
        let epoch = currentEpoch

        let task = scheduleDecodeTask(clipID: clipID, direction: direction) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    if var set = self.repairInflight[clipID] {
                        set.remove(quantized)
                        self.repairInflight[clipID] = set.isEmpty ? nil : set
                    }
                    if var map = self.repairTasks[clipID] {
                        map.removeValue(forKey: quantized)
                        self.repairTasks[clipID] = map.isEmpty ? nil : map
                    }
                }
            }

            let targetAbsMs = Int64((targetPTS * 1000.0).rounded())
            let sourceReady = await self.prepareSource(clipID: clipID,
                                                       decoder: decoder,
                                                       targetAbsMs: targetAbsMs,
                                                       reason: forceRetarget ? "repair_retarget" : "repair",
                                                       isDeadline: false,
                                                       cancelOthers: false)
            guard sourceReady else { return }

            let tolerance = max(frameDuration * 0.5, 0.02)
            let warmBias: TransportController.WarmFrameBias = direction == .reverse ? .reverse : .forward
            let alreadyWarm = await MainActor.run {
                TransportController.shared.hasWarmFrame(for: clipID,
                                                        at: targetPTS,
                                                        tolerance: tolerance,
                                                        maxPastLag: frameDuration * 1.5,
                                                        bias: warmBias)
            }
            if alreadyWarm { return }

            var admitted = true
            if admissionEnabled {
                var attempts = 0
                admitted = false
                while attempts < 10 {
                    let immediate = forceRetarget || bypassRateGate
                    let admission = await self.admissionController.checkAdmission(clipID: clipID,
                                                                                 direction: direction,
                                                                                 velocityFPS: velocityFPS,
                                                                                 isStop: false,
                                                                                 purpose: forceRetarget ? "repair_retarget" : "repair",
                                                                                 needsImmediate: immediate,
                                                                                 warmBehind: 0,
                                                                                 warmRequired: config.reverseLZFrames)
                    if admission.admitted {
                        admitted = true
                        break
                    }
                    if admission.reason == "rate_gate" || admission.reason == "clip_limit" {
                        attempts += 1
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    return
                }
                if !admitted { return }
            }

            await self.admissionController.markStarted(clipID: clipID, direction: direction)

            var needsRetarget = false
            var repairCompleted = false

            do {
                try Task.checkCancellation()
                let (buffer, pts) = try await decoder.decodeFrameSimple(at: targetPTS,
                                                                        tPred: basePTS,
                                                                        direction: direction)
                let delta = targetPTS - pts
                if abs(delta) > frameDuration * 1.5 {
                    if verboseLogging {
                        print("⚠️ [IntegratedScrubPipeline] Repair decode far clip=\(clipID) target=\(String(format: "%.3f", targetPTS)) actual=\(String(format: "%.3f", pts)) Δ=\(String(format: "%.3f", delta))s")
                    }
                }
                await MainActor.run {
                    TransportController.shared.cacheFrame(buffer,
                                                          clipID: clipID,
                                                          presentationTime: pts,
                                                          version: epoch,
                                                          origin: .scrub,
                                                          storeInPrimary: false)
                    let trailingAllowance = max(frameDuration, min(frameDuration * 4.0, 0.02))
                    let cutoff = max(targetPTS - trailingAllowance, 0)
                    TransportController.shared.pruneHistory(for: clipID, keepingAfter: cutoff)
                    self.decodeSuccessCount[clipID, default: 0] += 1
                }
                await MainActor.run {
                    self.clearProxyOverride(for: clipID)
                }

                if abs(targetPTS - pts) > maxAheadWindow && !forceRetarget {
                    needsRetarget = true
                }
                repairCompleted = true
            } catch is CancellationError {
                if self.stableReverse {
                    await MainActor.run {
                        ReverseScrubDiagnostics.shared.logWatchdog(clipID: clipID,
                                                                  reason: "timeout")
                    }
                }
            } catch {
                if verboseLogging {
                    print("[IntegratedScrubPipeline] Repair decode failed for clip \(clipID): \(error)")
                }
            }

            if repairCompleted {
                await self.admissionController.markCompleted(clipID: clipID, direction: direction)
            } else {
                await self.admissionController.onDecodeFailureOrTimeout(clipID: clipID, direction: direction)
            }

            if needsRetarget {
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logRepair(errorFrames: 0,
                                                             offsetSeconds: basePTS - targetPTS,
                                                             retarget: true)
                    self.enqueueRepairDecode(clipID: clipID,
                                             decoder: decoder,
                                             targetPTS: basePTS,
                                             basePTS: basePTS,
                                             direction: direction,
                                             frameDuration: frameDuration,
                                             velocityFPS: velocityFPS,
                                             maxAheadWindow: maxAheadWindow,
                                             forceRetarget: true)
                }
            }
        }
        var tasks = repairTasks[clipID] ?? [:]
        tasks[quantized] = task
        repairTasks[clipID] = tasks
    }
    


    private func makeDecodeTargets(clipID: UUID,
                                   tNow: TimeInterval,
                                   tPred: TimeInterval,
                                   direction: ScrubCoordinator.ScrubDirection,
                                   landingZone: LandingZoneManager.LandingZone?,
                                   frameDuration: Double,
                                   warmBehindCount: Int,
                                   warmAheadCount: Int,
                                   velocityFPS: Double,
                                   proxyOverrideActive: Bool) -> [DecodeTarget] {
        struct Candidate {
            let target: DecodeTarget
            let cost: Double
        }

        var seen: Set<Int64> = []
        var candidates: [Candidate] = []

        let quantizer = { (time: TimeInterval) -> Int64 in
            let clamped = max(time, 0)
            return Int64((clamped * 1000.0).rounded())
        }

        let frameDurationSafe = max(frameDuration, 1e-4)
        let isReverse = direction == .reverse
        let warmBias: TransportController.WarmFrameBias = isReverse ? .reverse : .forward

        let basePredSnapshot = quantizedCursor(for: clipID,
                                               rawTime: tPred,
                                               direction: direction,
                                               frameDuration: frameDurationSafe,
                                               velocityFPS: velocityFPS,
                                               access: .advance)
        var basePred = basePredSnapshot.pts

        let baseNowSnapshot = quantizedCursor(for: clipID,
                                              rawTime: tNow,
                                              direction: direction,
                                              frameDuration: frameDurationSafe,
                                              velocityFPS: velocityFPS,
                                              access: .observe(reference: (isReverse && !basePredSnapshot.didResetForDirectionChange) ? basePredSnapshot.index : nil))
        var baseNow = baseNowSnapshot.pts

        if !isReverse {
            reverseFrameCursor[clipID] = nil
            lastDirectionChangeTime[clipID] = nil
            lastRequestedIndex[clipID] = nil
        }

        let directionChange = isReverse ? (basePredSnapshot.didResetForDirectionChange || baseNowSnapshot.didResetForDirectionChange) : false

        if isReverse, let anchor = reverseRecoveryAnchor[clipID] {
            if basePred > anchor {
                basePred = anchor
            }
            if baseNow > anchor {
                baseNow = anchor
            }
        }

        if proxyOverrideActive && warmBehindCount == 0 {
            if let landingZone {
                basePred = min(basePred, landingZone.behindRange.upperBound)
                baseNow = min(baseNow, landingZone.behindRange.upperBound)
            } else {
                let clampTarget = min(tPred, tNow)
                basePred = min(basePred, clampTarget)
                baseNow = min(baseNow, clampTarget)
            }
        }

        if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled && isReverse {
            print("[PTS_BASE] clip=\(clipID.uuidString.prefix(8)) predIdx=\(basePredSnapshot.index) nowIdx=\(baseNowSnapshot.index) reqNow=\(baseNowSnapshot.requestedIndex) dirChange=\(directionChange)")
        }

        let maxAheadWindow = isReverse
            ? adaptiveReverseAheadWindow(frameDuration: frameDurationSafe, velocityFPS: velocityFPS)
            : min(frameDurationSafe * 0.75, 0.030)
        let hardAheadGuard = isReverse
            ? max(maxAheadWindow * 1.75, frameDurationSafe * 2.5)
            : maxAheadWindow
        let aheadPenalty = 0.75

        var remainingAheadSlots = isReverse ? (directionChange ? 2 : (stableReverse ? 2 : 1)) : 2
        if proxyOverrideActive && isReverse {
            remainingAheadSlots = min(remainingAheadSlots, 1)
        }
        // Target budget tuned to keep VT stable while still backfilling reverse gaps
        let targetBudget = isReverse ? (proxyOverrideActive ? 1 : 3) : 4

        let requiredBehindBase = max(config.reverseLZFrames, 1)
        let requiredBehind = landingZone.map { max($0.windowFrames, requiredBehindBase) } ?? requiredBehindBase
        let safetyReverseRefill = isReverse ? max(2, requiredBehindBase / 2) : 0

        var lzSlotsRemaining = max(requiredBehind - warmBehindCount, 0)
        if landingZone == nil {
            lzSlotsRemaining = max(lzSlotsRemaining, requiredBehindBase - warmBehindCount)
        }
        if isReverse {
            lzSlotsRemaining = max(lzSlotsRemaining, safetyReverseRefill)
        }

        let minAheadRefill = isReverse ? 1 : 0
        var lookAheadSlotsRemaining = max(config.forwardLZFrames - warmAheadCount, 0)
        if proxyOverrideActive && isReverse {
            lookAheadSlotsRemaining = min(lookAheadSlotsRemaining, 1)
        }
        lookAheadSlotsRemaining = max(lookAheadSlotsRemaining, minAheadRefill)

        let baseTolerance = max(frameDurationSafe * 0.30, 0.010)
        let tightTolerance = max(frameDurationSafe * 0.15, 0.005)

        func hasWarmFrame(pts: TimeInterval, reason: String) -> Bool {
            let tolerance: TimeInterval
            switch reason {
            case "pred", "now":
                tolerance = tightTolerance
            default:
                tolerance = baseTolerance
            }
            let maxLag = isReverse ? frameDurationSafe * 1.5 : .infinity
            return TransportController.shared.hasWarmFrame(for: clipID,
                                                           at: pts,
                                                           tolerance: tolerance,
                                                           maxPastLag: maxLag,
                                                           bias: warmBias)
        }

        func consider(_ pts: TimeInterval, storeInPrimary: Bool, reason: String, force: Bool = false) {
            let key = quantizer(pts)
            guard pts.isFinite, !seen.contains(key) else { return }

            var remainingStore = storeInPrimary
            var localRemainingAheadSlots = remainingAheadSlots
            let delta = pts - basePred
            let displayLead = pts - TransportController.shared.latchedTime

            let treatAsBehindRefill = reason == "lz" || (landingZone == nil && reason == "fallback_prev")
            let treatAsAheadRefill = reason == "lz_ahead" || (landingZone == nil && reason == "fallback_next")

            let needsRefill = isReverse && (
                (treatAsBehindRefill && (lzSlotsRemaining > 0 || safetyReverseRefill > 0)) ||
                (treatAsAheadRefill && (lookAheadSlotsRemaining > 0 || minAheadRefill > 0))
            )

            if !force && hasWarmFrame(pts: pts, reason: reason) && !needsRefill {
                return
            }

            if isReverse {
                if displayLead > config.reverseFutureLeadCap && !force {
                    if ScrubFeatureFlags.shared.telemetryEnabled {
                        print("[TARGET_SKIP_FUTURE] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) lead=\(String(format: "%.3f", displayLead)) reason=\(reason)")
                    }
                    return
                }

                if delta <= 0 {
                    remainingStore = true
                } else {
                    remainingStore = false
                }

                if delta > hardAheadGuard {
                    if !force { return }
                } else if delta > maxAheadWindow {
                    guard localRemainingAheadSlots > 0 else { return }
                    localRemainingAheadSlots -= 1
                } else if delta > 0 && localRemainingAheadSlots <= 0 {
                    return
                }
            }

            switch reason {
            case _ where treatAsBehindRefill:
                guard lzSlotsRemaining > 0 else { return }
                lzSlotsRemaining -= 1
            case _ where treatAsAheadRefill:
                guard lookAheadSlotsRemaining > 0 else { return }
                lookAheadSlotsRemaining -= 1
            default:
                break
            }

            if isReverse {
                remainingAheadSlots = localRemainingAheadSlots
            }

            let normalized = abs(delta) / frameDurationSafe
            let penalty = delta > 0 ? aheadPenalty : 0
            let cost = normalized + penalty

            seen.insert(key)
            candidates.append(Candidate(target: DecodeTarget(pts: max(pts, 0),
                                                             storeInPrimary: remainingStore,
                                                             reason: reason),
                                        cost: cost))
        }

        consider(basePred, storeInPrimary: false, reason: "pred")
        if abs(baseNow - basePred) > 0.0005 {
            consider(baseNow, storeInPrimary: false, reason: "now")
        }

        if let landingZone {
            let zonePTS = landingZoneManager.getPriorityPTS(landingZone: landingZone)
            for candidate in zonePTS {
                let reason = candidate <= landingZone.tPred ? "lz" : "lz_ahead"
                consider(candidate,
                         storeInPrimary: false,
                         reason: reason,
                         force: isReverse && reason == "lz")
            }
        } else {
            consider(basePred - frameDurationSafe,
                     storeInPrimary: false,
                     reason: "fallback_prev",
                     force: isReverse)
            consider(basePred + frameDurationSafe,
                     storeInPrimary: false,
                     reason: "fallback_next")
        }

        if abs(velocityFPS) >= 2.5 {
            switch direction {
            case .reverse:
                consider(basePred - frameDurationSafe, storeInPrimary: false, reason: "repairBehind")
                consider(basePred + frameDurationSafe, storeInPrimary: false, reason: "repairAhead")
            case .forward:
                consider(basePred + frameDurationSafe, storeInPrimary: false, reason: "repairAhead")
                consider(basePred - frameDurationSafe, storeInPrimary: false, reason: "repairBehind")
            }
        }

        guard !candidates.isEmpty else { return [] }

        let limited = candidates
            .sorted { lhs, rhs in
                if abs(lhs.cost - rhs.cost) < 1e-6 {
                    return lhs.target.reason < rhs.target.reason
                }
                return lhs.cost < rhs.cost
            }
            .prefix(targetBudget)

        let selectedPairs = limited.map { ($0.target.pts, $0.target.reason) }
        let droppedCount = candidates.count - selectedPairs.count
        let windowFill = requiredBehind > 0
            ? Double(min(warmBehindCount, requiredBehind)) / Double(requiredBehind)
            : (warmBehindCount > 0 ? 1.0 : 0.0)

        ReverseScrubDiagnostics.shared.logTargetSelection(tPred: basePred,
                                                          selected: selectedPairs,
                                                          droppedFar: droppedCount,
                                                          windowFill: windowFill)
        if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
            let selectedDesc = selectedPairs.map { pts, reason in
                "\(String(format: "%.3f", pts))@\(reason)"
            }.joined(separator: ",")
            print("[PTS_TARGETS] clip=\(clipID.uuidString.prefix(8)) basePred=\(String(format: "%.3f", basePred)) baseNow=\(String(format: "%.3f", baseNow)) selected=[\(selectedDesc)]")
        }

        return limited.map { $0.target }
    }


    private func quantizedCursor(for clipID: UUID,
                                 rawTime: TimeInterval,
                                 direction: ScrubCoordinator.ScrubDirection,
                                 frameDuration: TimeInterval,
                                 velocityFPS: Double,
                                 access: ReverseCursorAccessMode) -> ReverseCursorSnapshot {
        let safeFrameDuration = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 60.0

        guard StableScrubMode.enabled else {
            let snapped = max(rawTime, 0)
            let index = max(Int((snapped / safeFrameDuration).rounded(.down)), 0)
            return ReverseCursorSnapshot(pts: snapped,
                                         index: index,
                                         requestedIndex: index,
                                         didResetForDirectionChange: false)
        }

        switch direction {
        case .forward:
            let snapped = max(rawTime, 0)
            let index = max(Int((snapped / safeFrameDuration).rounded(.down)), 0)
            reverseFrameCursor[clipID] = nil
            lastDirectionChangeTime[clipID] = nil
            lastRequestedIndex[clipID] = nil
            if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) raw=\(String(format: "%.3f", rawTime)) dir=fwd snapped=\(String(format: "%.3f", snapped))")
            }
            return ReverseCursorSnapshot(pts: snapped,
                                         index: index,
                                         requestedIndex: index,
                                         didResetForDirectionChange: false)

        case .reverse:
            let normalizedTime = max(rawTime, 0)
            let requestedIndex = max(Int((normalizedTime / safeFrameDuration).rounded(.down)), 0)
            let now = CFAbsoluteTimeGetCurrent()
            let maxLagFrames = max(config.reverseLZFrames * 3, 12)

            var targetIndex = reverseFrameCursor[clipID] ?? requestedIndex
            if reverseFrameCursor[clipID] == nil {
                reverseFrameCursor[clipID] = requestedIndex
                targetIndex = requestedIndex
                lastDirectionChangeTime[clipID] = now
                if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                    print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) raw=\(String(format: "%.3f", rawTime)) dir=rev init=\(requestedIndex) step=\(String(format: "%.5f", safeFrameDuration))")
                }
            }

            var didReset = false

            switch access {
            case .advance:
                if requestedIndex < targetIndex {
                    // User jumped backward or cursor catching up - update immediately
                    targetIndex = requestedIndex
                    reverseFrameCursor[clipID] = targetIndex
                } else if requestedIndex > targetIndex {
                    // CRITICAL FIX: During reverse scrubbing, requestedIndex > targetIndex is NORMAL
                    // because playhead moves forward while cursor moves backward via commitReverseCursor
                    // Only reset cursor for LARGE timeline jumps, not normal drift
                    let timeSinceLastChange = now - (lastDirectionChangeTime[clipID] ?? 0)
                    let deltaFrames = requestedIndex - targetIndex

                    // Much stricter threshold: only reset for genuine timeline jumps (30+ frames AND 1+ sec)
                    let isLargeJump = deltaFrames >= 30 && timeSinceLastChange >= 1.0

                    if isLargeJump {
                        targetIndex = requestedIndex
                        reverseFrameCursor[clipID] = targetIndex
                        lastDirectionChangeTime[clipID] = now
                        if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                            print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) advance LARGE JUMP delta=\(deltaFrames) elapsed=\(String(format: "%.2f", timeSinceLastChange))")
                        }
                    } else {
                        // KEEP current cursor - let it progress backward via commitReverseCursor
                        reverseFrameCursor[clipID] = targetIndex
                        if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled && deltaFrames > 3 {
                            print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) advance HOLD cursor delta=\(deltaFrames) (normal drift)")
                        }
                    }
                } else {
                    reverseFrameCursor[clipID] = targetIndex
                }

            case .observe(let reference):
                let previousObserved = lastRequestedIndex[clipID] ?? requestedIndex
                let requestDelta = requestedIndex - previousObserved
                lastRequestedIndex[clipID] = requestedIndex

                if requestedIndex < targetIndex {
                    // User jumped backward - update immediately
                    targetIndex = requestedIndex
                } else if requestedIndex > targetIndex {
                    // CRITICAL FIX: During reverse scrubbing, requestedIndex > targetIndex is EXPECTED
                    // Playhead moves forward while cursor moves backward via commitReverseCursor
                    // Only reset for LARGE timeline jumps, not normal progression
                    if velocityFPS < -0.1 {
                        // Reverse scrubbing: only reset for genuine large jumps
                        let timeSinceLastChange = now - (lastDirectionChangeTime[clipID] ?? 0)
                        let deltaFrames = requestedIndex - targetIndex

                        // Much stricter: only reset for 30+ frame jump AND 1+ sec elapsed
                        let isLargeJump = deltaFrames >= 30 && timeSinceLastChange >= 1.0

                        if isLargeJump {
                            targetIndex = requestedIndex
                            didReset = true
                            lastDirectionChangeTime[clipID] = now
                            if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                                print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) observe LARGE JUMP delta=\(deltaFrames)")
                            }
                        } else {
                            // KEEP current cursor - this is normal drift during reverse scrubbing
                            if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled && deltaFrames > 3 {
                                print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) observe HOLD cursor delta=\(deltaFrames) (normal drift)")
                            }
                        }
                    } else {
                        // Forward scrubbing: apply anti-jitter thresholds
                        let (frameThreshold, holdThreshold) = reverseCursorChangeThresholds(frameDuration: safeFrameDuration,
                                                                                            velocityFPS: velocityFPS)
                        let timeSinceLastChange = now - (lastDirectionChangeTime[clipID] ?? 0)
                        let deltaFrames = requestedIndex - targetIndex
                        let consistentForward = requestDelta > 1 || (abs(velocityFPS) < 0.35 && requestDelta > 0)

                        if deltaFrames >= frameThreshold && timeSinceLastChange >= holdThreshold && (consistentForward || deltaFrames >= frameThreshold * 2) {
                            targetIndex = requestedIndex
                            didReset = true
                            lastDirectionChangeTime[clipID] = now
                            if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                                print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) forward reset delta=\(deltaFrames) thr=\(frameThreshold) hold=\(String(format: "%.2f", holdThreshold))")
                            }
                        } else if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled && deltaFrames > 0 {
                            print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) ignore forward delta=\(deltaFrames) thr=\(frameThreshold) hold=\(String(format: "%.2f", holdThreshold)) elapsed=\(String(format: "%.2f", timeSinceLastChange))")
                        }
                    }
                }

                if let reference, targetIndex > reference {
                    targetIndex = reference
                }

                reverseFrameCursor[clipID] = targetIndex
            }

            let minAllowedIndex = max(requestedIndex - maxLagFrames, 0)
            if targetIndex < minAllowedIndex {
                targetIndex = minAllowedIndex
                reverseFrameCursor[clipID] = targetIndex
            }

            let snapped = Double(targetIndex) * safeFrameDuration
            if stableReverse && ScrubFeatureFlags.shared.telemetryEnabled {
                print("[PTS_QUANTIZE] clip=\(clipID.uuidString.prefix(8)) raw=\(String(format: "%.3f", rawTime)) dir=rev targetIndex=\(targetIndex) req=\(requestedIndex) step=\(String(format: "%.5f", safeFrameDuration)) snapped=\(String(format: "%.3f", snapped))")
            }
            return ReverseCursorSnapshot(pts: snapped,
                                         index: targetIndex,
                                         requestedIndex: requestedIndex,
                                         didResetForDirectionChange: didReset)
        }
    }

    private func reverseCursorChangeThresholds(frameDuration: TimeInterval,
                                               velocityFPS: Double) -> (Int, TimeInterval) {
        let speed = abs(velocityFPS)
        let baseFrames: Int
        let hold: TimeInterval

        switch speed {
        case ..<0.2:
            baseFrames = 3
            hold = 0.18
        case ..<0.5:
            baseFrames = 4
            hold = 0.16
        case ..<1.0:
            baseFrames = 6
            hold = 0.14
        case ..<2.5:
            baseFrames = 8
            hold = 0.12
        case ..<5.0:
            baseFrames = 10
            hold = 0.10
        default:
            baseFrames = 14
            hold = 0.08
        }

        let minFrames = max(3, Int(ceil(0.12 / max(frameDuration, 1e-6))))
        let frames = min(max(baseFrames, minFrames), 24)
        return (frames, hold)
    }

    private func adaptiveReverseAheadWindow(frameDuration: Double,
                                            velocityFPS: Double) -> TimeInterval {
        let safeFrameDuration = max(frameDuration, 1.0 / 240.0)
        let speed = abs(velocityFPS)

        let multiplier: Double
        switch speed {
        case ..<0.25:
            multiplier = 2.0
        case ..<0.75:
            multiplier = 1.6
        case ..<1.5:
            multiplier = 1.3
        case ..<3.0:
            multiplier = 1.1
        default:
            multiplier = 0.9
        }

        let base = safeFrameDuration * multiplier
        let minWindow = max(safeFrameDuration * 0.75, 0.028)
        let maxWindow = max(safeFrameDuration * 3.0, 0.065)
        return min(max(base, minWindow), maxWindow)
    }

    private func commitReverseCursor(for clipID: UUID) {
        guard var current = reverseFrameCursor[clipID] else { return }
        if current > 0 {
            current -= 1
            reverseFrameCursor[clipID] = current
        }
        if ScrubFeatureFlags.shared.telemetryEnabled {
            print("[PTS_COMMIT] clip=\(clipID.uuidString.prefix(8)) nextIndex=\(current)")
        }
    }
    
    private func computeGOPKey(for pts: TimeInterval, frameDuration: Double) -> TimeInterval {
        let gopSpan = max(frameDuration * 12.0, 0.5)
        let index = floor(pts / gopSpan)
        return index * gopSpan
    }
}
