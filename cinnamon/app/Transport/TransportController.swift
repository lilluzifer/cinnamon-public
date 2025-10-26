import Combine
import Foundation
import CoreGraphics
import CoreMedia
import QuartzCore
import Dispatch
import AVFoundation
import simd

private struct TransportPlaybackGraph {
    var version: Int
    var segments: [TimelineSegment]
    var duration: TimeInterval
    var compositeSlices: [TimelineCompositeSlice]

    static let empty = TransportPlaybackGraph(version: 0,
                                              segments: [],
                                              duration: 0,
                                              compositeSlices: [])
}

public enum TransportPlaybackState: Sendable, Equatable {
    case paused
    case playing
    case scrubbing
}

@MainActor
final class TransportController: ObservableObject {
    enum WarmFrameBias {
        case neutral
        case forward
        case reverse
    }
    static let shared = TransportController()

    @Published private(set) var latchedTime: TimeInterval = 0
    @Published private(set) var latchedPlaybackRate: Double = 0
    @Published private(set) var isScrubbing: Bool = false
    @Published private(set) var isGapActive: Bool = false
    @Published private(set) var playbackState: TransportPlaybackState = .paused

    private var playbackGraph = TransportPlaybackGraph.empty
    private var resumeAfterScrub = false
    private var scrubResumeRate: Double = 1.0
    private var currentSegmentIndex: Int?
    private var gapTimer: Timer?
    private var gapTimerStartHostTime: CFTimeInterval?
    private var gapTimelineStart: TimeInterval?
    private var gapTelemetryMarked = false
    private var monotonicGuardEnabled = false
    private var uiWantsPlay = false
    private var lastPreloadCheckTime: TimeInterval = 0
    private var isTransitioningSegments = false
    private var isFrozenForDrag = false
    private var preparedClipSegmentIndex: Int?
    private var preparingClipSegmentIndex: Int?
    private var compositeWarningLogged = false
    
    // Phase 3 + Phase 2: Integrated Scrub Pipeline
    private var integratedScrubPipeline: IntegratedScrubPipeline?
    private var scrubPipelineEnabled: Bool {
        // CRITICAL FIX: Only enable during SCRUBBING, not PLAYBACK!
        // During playback we need the old pipeline for frame lookahead/buffering
        return playbackState == .scrubbing
    }
    private let audioMixer = TimelineAudioMixer()
    private var currentCompositeSliceIndex: Int?
    private var videoSources: [UUID: VideoSource] = [:]
    private var clipNaturalSizes: [UUID: CGSize] = [:]
    private let playbackClock = PlaybackClock.shared
    private let timelineTicker = TimelineTicker()
    private var isTimelineTickerActive = false
    private var tickerWarmupTask: Task<Void, Never>? = nil
    private var frameDuration: TimeInterval = 1.0 / 60.0  // Composition timeline rate (not video rate!)
    private let scrubCoordinator = ScrubCoordinator()  // Active scrub pipeline coordinator
    private let compositionID = UUID()
    private var canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    private let defaultCanvasSize = CGSize(width: 1920, height: 1080)
    private let renderTileSize: CGFloat = 256
    private struct TileIndex: Hashable { let x: Int; let y: Int }
    private var pendingDirtyTiles: Set<TileIndex> = []

    // DEBUG tracking
    private var debugLoopCount = 0
    private var debugLastLoopLogTime = CFAbsoluteTimeGetCurrent()
    private var debugLastLogTime: TimeInterval = 0
    private var debugFrameCount = 0
    private var debugLastClockLog = CFAbsoluteTimeGetCurrent()
    private var lastDisplayedPTS: [UUID: TimeInterval] = [:]
    private var lastSwapTime: [UUID: CFAbsoluteTime] = [:]
    private let hystMS: Double = 14.0  // Hysteresis threshold in milliseconds
    private let minHoldMS: Double = 25.0  // Minimum hold duration before swapping frames
    private let staleRelaxThresholdMS: Double = 350.0
    private let staleRelaxMinImprovementMS: Double = 3.0
    private var lateFrameSkipCount = 0
    private var clipPrimedForDisplay: Set<UUID> = []

    private func shouldSwapFrame(candidatePTS: TimeInterval,
                                 currentPTS: TimeInterval?,
                                 sampleTime: TimeInterval,
                                 ageMS: Double,
                                 clipID: UUID,
                                 frameDuration: TimeInterval) -> (Bool, String) {
        let lead = candidatePTS - sampleTime
        let leadTolerance = 0.0005  // 0.5ms tolerance for rounding errors

        // Never display future frames
        if lead > leadTolerance {
            playbackDebugLog("🔁 [swap] Reject future frame clip=\(clipID) lead=\(lead)")
            return (false, "future_frame")
        }

        guard let currentPTS else {
            return (true, "cold")
        }

        if ageMS < minHoldMS {
            return (false, "hold")
        }

        let currentDistance = abs(sampleTime - currentPTS)
        let candidateDistance = abs(sampleTime - candidatePTS)
        let improvementMS = (currentDistance - candidateDistance) * 1000

        // Reject candidates that are too far from the requested sample even if they improve marginally
        let maxDistance = max(frameDuration * 1.0, 0.04)
        if candidateDistance > maxDistance {
            playbackDebugLog("🚫 [swap] Reject far candidate clip=\(clipID) candidate=\(String(format: "%.4f", candidatePTS)) sample=\(String(format: "%.4f", sampleTime)) distance=\(String(format: "%.4f", candidateDistance))")
            return (false, "distance")
        }

        if improvementMS < hystMS {
            if improvementMS > staleRelaxMinImprovementMS && ageMS >= staleRelaxThresholdMS {
                return (true, "stale_relax")
            }
            return (false, "hysteresis")
        }

        return (true, "np")
    }

    /// Update the timeline ticker's framerate for proper timing
    func updateCompositionFrameRate(_ frameRate: Double) {
        let timebase = FrameTimebase(frameRate: frameRate)
        // AFTER EFFECTS BEHAVIOR: Timeline runs at COMPOSITION framerate (global setting)
        timelineTicker.setCompositionFrameRate(frameRate)
        // frameDuration = composition timeline interval (NOT video framerate!)
        let oldFrameDuration = frameDuration
        frameDuration = 1.0 / frameRate
        currentFrameTimebase = timebase
        print("🔧 [DEBUG] Composition framerate set to \(frameRate)fps")
        print("   Timeline interval: \(String(format: "%.4f", frameDuration))s per frame")
        print("   Videos play at NATIVE framerate (independent of composition)")
    }

    private var currentFrameTimebase: FrameTimebase = FrameTimebase(frameRate: 24.0)

    /// Get current composition framerate for rendering calculations
    var compositionFrameRate: Double {
        return currentFrameTimebase.framesPerSecond.doubleValue
    }

    /// Get the frame-exact timebase for NLE-accurate timing
    var frameTimebase: FrameTimebase {
        return currentFrameTimebase
    }
    var currentTime: TimeInterval { playbackClock.currentTime() }
    var desiredAudioMute: Bool = false {
        didSet {
            audioMixer.setMuted(desiredAudioMute)
            if desiredAudioMute {
                audioMixer.pauseAll()
            } else if playbackState == .playing && latchedPlaybackRate != 0 {
                updateAudioForCurrentTime(playing: true, force: true)
            }
        }
    }

    private init() {
        playbackClock.pause(at: latchedTime)
        _ = PlaybackTelemetry.shared
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(canvasSizeChanged(_:)),
                                               name: Notification.Name("CanvasSizeChanged"),
                                               object: nil)
    }

    func pauseForDrag() {
        guard !isFrozenForDrag else { return }
        isFrozenForDrag = true

        // Stop playback if playing
        if latchedPlaybackRate != 0 {
            stopTimelineTicker()
        }

        print("[Transport] FROZEN for drag")
    }

    func resumeAfterDrag() {
        guard isFrozenForDrag else { return }
        isFrozenForDrag = false

        print("[Transport] RESUMED after drag")
    }

    @discardableResult
    func applyComposition(_ composition: Composition) -> TimelinePlaybackData {
        // CRITICAL: Do NOT set frameDuration from composition - videos use native rates
        // frameDuration is only for timeline UI calculations, not video playback
        let playbackData = TimelinePlaybackMapper.segments(for: composition)
        rebuildVideoSources(for: composition)

        // Remember if we were playing before applying new composition
        let wasPlaying = playbackState == .playing && uiWantsPlay
        let savedRate = abs(latchedPlaybackRate) > 1e-6 ? latchedPlaybackRate : 1.0
        let savedTime = latchedTime

        applyPlaybackTimeline(playbackData.timeline,
                              duration: composition.duration,
                              compositeSlices: playbackData.compositeTimeline)

        updateDirtyRegions(for: composition)

        // Start buffering immediately for new composition
        startFrameBuffering()

        // Resume playback if we were playing before
        if wasPlaying {
            // Ensure we're at a valid position
            latchedTime = clampTimelineTime(savedTime)
            playbackClock.seek(to: latchedTime)

            // Immediately resume without delay
            requestPlay(rate: savedRate, completion: nil)
        }

        return playbackData
    }

    func compositeSegments(at time: TimeInterval) -> [TimelineSegment] {
        return activeAudioSegments(at: time)
    }

    // Frame pipeline for non-blocking rendering
    private let framePipeline = FramePipeline()
    private var frameBuffer: [UUID: CVPixelBuffer] = [:]  // Fallback for scrubbing / warmup
    private var frameBufferTimestamps: [UUID: TimeInterval] = [:]
    private var frameHistory: [UUID: FrameHistoryManager] = [:]
    private var activeClipFrameTask: Task<Void, Never>?
    private var activeClipFrameTaskStartTime: CFAbsoluteTime?
    private var lastActiveClipFrameRequest: TimeInterval = -Double.infinity
    private var bufferUpdateTask: Task<Void, Never>?
    private var scrubSeekTask: Task<Void, Never>?  // Track scrubSeek async tasks
    private var scrubCatchupTask: Task<Void, Never>?
    private var pendingScrubTime: TimeInterval?
    private var lastBufferUpdateTime: TimeInterval = -1

    // CRITICAL FIX (Bug #14): Per-source throttling timestamps
    // Can't use single shared timestamp - frameBufferingLoop resets it and blocks scrubSeek!
    private var lastUpdateFrameBufferTime: [String: CFAbsoluteTime] = [:]

    // CRITICAL BUG #13 FIX: Version counter to prevent out-of-order frame caching
    // When user scrubs quickly (5.0s → 4.9s → 4.8s), multiple async tasks start:
    // - scrubSeek(5.0s) starts Task v1
    // - scrubSeek(4.9s) starts Task v2, cancels v1
    // - scrubSeek(4.8s) starts Task v3, cancels v2
    // But v1 and v2 are already loading frames! When they finish, they check version.
    // Only v3 (latest) is allowed to cache frames.
    private var scrubSeekVersion: UInt64 = 0  // Increments on each scrubSeek
    private var currentFrameUpdateVersion: UInt64 = 0  // What version is allowed to cache

    private let isPlaybackDebugLoggingEnabled = ProcessInfo.processInfo.environment["PLAYBACK_DEBUG_LOGS"] == "1"

    private func playbackDebugLog(_ message: @autoclosure () -> String) {
        guard isPlaybackDebugLoggingEnabled else { return }
        print(message())
    }

    private func videoFrameDuration(for clipID: UUID) -> TimeInterval {
        framePipeline.frameDuration(for: clipID) ?? frameDuration
    }

    private func leadAllowance(for clipID: UUID,
                               framesAhead: Double,
                               minimum: TimeInterval,
                               maximum: TimeInterval? = nil) -> TimeInterval {
        let base = max(videoFrameDuration(for: clipID) * framesAhead, minimum)
        if let maximum {
            return min(base, maximum)
        }
        return base
    }

    private func historyBiasWindow(for clipID: UUID, cacheFrames: Int) -> TimeInterval {
        let frameDuration = max(videoFrameDuration(for: clipID), 1.0 / 90.0)
        return frameDuration * Double(max(cacheFrames, 1))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @MainActor
    func warmFrameCount(for clipID: UUID, in range: ClosedRange<TimeInterval>) -> Int {
        let frameDuration = max(videoFrameDuration(for: clipID), 1.0 / 120.0)
        let history = frameHistory[clipID]
        let historyCount = history?.count(in: range) ?? 0

        var total = historyCount
        if let timestamp = frameBufferTimestamps[clipID], range.contains(timestamp) {
            let alreadyTracked = history?.contains(time: timestamp, tolerance: frameDuration * 0.25) ?? false
            if !alreadyTracked {
                total += 1
            }
        }

        if ScrubFeatureFlags.shared.telemetryEnabled && ScrubFeatureFlags.shared.verboseLogging {
            let key = clipID.uuidString.prefix(8)
            let debugRange = String(format: "%.3f…%.3f", range.lowerBound, range.upperBound)
            print("[WARM_COUNT] clip=\(key) range=\(debugRange) history=\(historyCount) total=\(total)")
        }

        return total
    }

    @MainActor
    func warmFrameTimes(for clipID: UUID,
                        in range: ClosedRange<TimeInterval>,
                        limit: Int = 12) -> [TimeInterval] {
        let frameDuration = max(videoFrameDuration(for: clipID), 1.0 / 120.0)
        var times = frameHistory[clipID]?.times(in: range) ?? []

        if let timestamp = frameBufferTimestamps[clipID], range.contains(timestamp) {
            let alreadyPresent = times.contains { abs($0 - timestamp) <= frameDuration * 0.25 }
            if !alreadyPresent {
                times.append(timestamp)
                times.sort()
            }
        }

        if times.count <= limit {
            return times
        }

        var sampled: [TimeInterval] = []
        let step = max(times.count / limit, 1)
        for (index, time) in times.enumerated() where index % step == 0 {
            sampled.append(time)
            if sampled.count == limit {
                break
            }
        }
        return sampled
    }

    func pruneHistory(for clipID: UUID, keepingAfter cutoff: TimeInterval) {
        guard let history = frameHistory[clipID] else { return }
        history.remove(before: cutoff)
    }

    @MainActor
    func hasWarmFrame(for clipID: UUID,
                      at time: TimeInterval,
                      tolerance: TimeInterval,
                      maxPastLag: TimeInterval = .infinity,
                      bias: WarmFrameBias = .neutral) -> Bool {
        let epsilon = max(tolerance, 1e-6)

        func passesBias(_ frameTime: TimeInterval) -> Bool {
            switch bias {
            case .neutral:
                return true
            case .reverse:
                return frameTime <= time + epsilon
            case .forward:
                return frameTime + epsilon >= time
            }
        }

        if let timestamp = frameBufferTimestamps[clipID],
           abs(timestamp - time) <= epsilon,
           passesBias(timestamp) {
            if time - timestamp <= maxPastLag { return true }
        }

        if let history = frameHistory[clipID],
           let (_, frameTime) = history.frame(at: time, tolerance: epsilon),
           passesBias(frameTime) {
            if time - frameTime <= maxPastLag { return true }
        }

        return false
    }

    // CRITICAL BUG #14 FIX: Throttle scrubSeek to prevent UI freezing
    // Professional NLE behavior (Premiere Pro, Final Cut Pro, DaVinci Resolve):
    // - Scrubbing frame loading limited to 60fps (16.67ms intervals) via scheduleFrameUpdate()
    // - Playhead position updates immediately (responsive UI)
    // - Frame decoding throttled (prevents MainActor overload)
    // Without throttling: 100+ parallel async tasks → MainActor frozen → UI freeze

    func pixelBufferSync(for clipID: UUID, at time: TimeInterval) -> CVPixelBuffer? {
        let isPlayback = playbackState == .playing
        let isScrubbingState = playbackState == .scrubbing
        let clipFrameDuration = videoFrameDuration(for: clipID)
        let tolerance = isPlayback
            ? max(clipFrameDuration * 3.0, 1.0 / 90.0)
            : max(clipFrameDuration * 2.0, 1.0 / 60.0)
        let playbackLeadAllowance = leadAllowance(for: clipID,
                                                 framesAhead: 6.0,
                                                 minimum: 0.18,
                                                 maximum: 0.5)
        let pauseLeadAllowance = leadAllowance(for: clipID,
                                              framesAhead: 7.0,
                                              minimum: playbackLeadAllowance,
                                              maximum: 0.6)
        let scrubLeadAllowance = leadAllowance(for: clipID,
                                              framesAhead: 3.0,
                                              minimum: max(playbackLeadAllowance, 0.18),
                                              maximum: 0.25)
        let allowedLead: TimeInterval
        if isPlayback {
            allowedLead = playbackLeadAllowance
        } else if isScrubbingState {
            allowedLead = scrubLeadAllowance
        } else {
            allowedLead = pauseLeadAllowance
        }
        let useSafeFallback = playbackState != .playing
        let preferredHistoryVersion: UInt64? = playbackState == .scrubbing ? currentFrameUpdateVersion : nil
        let epsilon = max(clipFrameDuration * 0.001, 1e-6)
        let now = CFAbsoluteTimeGetCurrent()
        let useAntiFlicker = playbackState != .playing
        let currentDisplayedPTS = useAntiFlicker ? lastDisplayedPTS[clipID] : nil
        let ageMS = useAntiFlicker ? max((now - (lastSwapTime[clipID] ?? now)) * 1000.0, 0) : 0

        func attemptSwap(buffer: CVPixelBuffer, pts: TimeInterval, reason: String) -> (CVPixelBuffer, Bool)? {
            if !useAntiFlicker {
                lastDisplayedPTS[clipID] = pts
                lastSwapTime[clipID] = now
                frameBuffer[clipID] = buffer
                frameBufferTimestamps[clipID] = pts
                playbackDebugLog("✅ [swap] clip=\(clipID) pts=\(String(format: "%.4f", pts)) reason=\(reason) (anti-flicker off)")
                return (buffer, true)
            }

            let decision = shouldSwapFrame(candidatePTS: pts,
                                            currentPTS: currentDisplayedPTS,
                                            sampleTime: time,
                                            ageMS: ageMS,
                                            clipID: clipID,
                                            frameDuration: clipFrameDuration)

            ReverseScrubDiagnostics.shared.logDisplayDecision(clipID: clipID,
                                                               swapped: decision.0,
                                                               ageMS: ageMS,
                                                               holdReason: decision.1)

            if decision.0 {
                lastDisplayedPTS[clipID] = pts
                lastSwapTime[clipID] = now
                frameBuffer[clipID] = buffer
                frameBufferTimestamps[clipID] = pts
                playbackDebugLog("✅ [swap] clip=\(clipID) pts=\(String(format: "%.4f", pts)) reason=\(reason) gate=\(decision.1)")
                return (buffer, true)
            }

            playbackDebugLog("🔁 [swap] HOLD clip=\(clipID) reason=\(decision.1) age=\(String(format: "%.1f", ageMS))ms")

            if let currentPTS = currentDisplayedPTS,
               let existing = frameBuffer[clipID],
               let storedPTS = frameBufferTimestamps[clipID],
               storedPTS == currentPTS {
                playbackDebugLog("🔁 [swap] KEEP current buffer clip=\(clipID) pts=\(String(format: "%.4f", currentPTS))")
                AVSyncDiagnostics.shared.logSelection(
                    time: time,
                    clipID: clipID,
                    selectedPTS: currentPTS,
                    nextPTS: nil,
                    valid: true
                )
                return (existing, false)
           } else if let currentPTS = currentDisplayedPTS,
                     let history = frameHistory[clipID],
                      let exact = history.frame(at: currentPTS,
                                                tolerance: isScrubbingState ? max(clipFrameDuration * 1.5, 0.05)
                                                                            : max(clipFrameDuration * 0.5, 0.02)) {
                playbackDebugLog("🔁 [swap] HISTORY fallback clip=\(clipID) pts=\(String(format: "%.4f", exact.time)) (current=\(String(format: "%.4f", currentPTS)))")
                frameBuffer[clipID] = exact.buffer
                frameBufferTimestamps[clipID] = exact.time
                AVSyncDiagnostics.shared.logSelection(
                    time: time,
                    clipID: clipID,
                    selectedPTS: exact.time,
                    nextPTS: nil,
                    valid: true
                )
                return (exact.buffer, false)
            }
            playbackDebugLog("⚠️ [swap] No previous frame available for clip=\(clipID) (reason=\(decision.1))")
            return nil
        }

        if let pipelineFrame = framePipeline.frameMetadata(for: clipID, at: time) {
            let lead = pipelineFrame.presentationTime - time
            let reverseTolerance = lead < 0 ? min(max(abs(lead) + 0.05, allowedLead), 0.60) : allowedLead
            let effectiveTolerance = max(tolerance, reverseTolerance)
            if lead < -epsilon {
                ReverseScrubDiagnostics.shared.logLateFrame(clipID: clipID,
                                                            leadMS: lead * 1000.0,
                                                            usedForDisplay: lead <= allowedLead + epsilon)
            }
            if lead <= allowedLead + epsilon && abs(pipelineFrame.presentationTime - time) <= effectiveTolerance {
                if let result = attemptSwap(buffer: pipelineFrame.pixelBuffer,
                                            pts: pipelineFrame.presentationTime,
                                            reason: "pipeline") {
                    if result.1 {
                        AVSyncDiagnostics.shared.logSelection(
                            time: time,
                            clipID: clipID,
                            selectedPTS: pipelineFrame.presentationTime,
                            nextPTS: nil,
                            valid: true
                        )
                    }
                    return result.0
                }
            } else if lead > allowedLead + epsilon {
                // Frame rejected - too far in future
                AVSyncDiagnostics.shared.logSelection(
                    time: time,
                    clipID: clipID,
                    selectedPTS: pipelineFrame.presentationTime,
                    nextPTS: nil,
                    valid: false
                )
                playbackDebugLog("🚫 [pixelBufferSync] ignoring future pipeline frame for clip \(clipID) (lead=\(String(format: "%.3f", lead))s, state=\(playbackState))")
            }
        }

        if let cached = frameBuffer[clipID],
           let timestamp = frameBufferTimestamps[clipID] {
            let lead = timestamp - time
            
            // CRITICAL FIX: During scrubbing, accept frames with NEGATIVE lead (from past)
            // User scrubs backwards: frame at 4.1s is valid when user is at 3.8s (lead = +0.3s)
            // But also: frame at 3.8s is valid when user is at 4.1s (lead = -0.3s)
            let maxNegativeLead = isScrubbingState ? -1.0 : 0.0  // Allow 1s in past during scrubbing
            
            if lead >= maxNegativeLead && lead <= allowedLead + epsilon && abs(timestamp - time) <= max(tolerance, allowedLead) {
                if let result = attemptSwap(buffer: cached,
                                            pts: timestamp,
                                            reason: "cache") {
                    if result.1 {
                        AVSyncDiagnostics.shared.logSelection(
                            time: time,
                            clipID: clipID,
                            selectedPTS: timestamp,
                            nextPTS: nil,
                            valid: true
                        )
                    }
                    return result.0
                }
            } else if lead > allowedLead + epsilon {
                // Frame rejected - too far in future
                AVSyncDiagnostics.shared.logSelection(
                    time: time,
                    clipID: clipID,
                    selectedPTS: timestamp,
                    nextPTS: nil,
                    valid: false
                )
                playbackDebugLog("🚫 [pixelBufferSync] ignoring cached future frame for clip \(clipID) (lead=\(String(format: "%.3f", lead))s, state=\(playbackState))")
            } else if lead < maxNegativeLead {
                // Frame rejected - too far in past
                playbackDebugLog("🚫 [pixelBufferSync] ignoring cached past frame for clip \(clipID) (lead=\(String(format: "%.3f", lead))s, state=\(playbackState))")
            }
        }

        if isPlayback, let lastFrame = frameBuffer[clipID],
           let timestamp = frameBufferTimestamps[clipID] {
            // A/V Sync Diagnostics: Log last frame fallback
            AVSyncDiagnostics.shared.logSelection(
                time: time,
                clipID: clipID,
                selectedPTS: timestamp,
                nextPTS: nil,
                valid: true  // Best available during playback
            )
            lastDisplayedPTS[clipID] = timestamp
            lastSwapTime[clipID] = now
            return lastFrame
        }

        if useSafeFallback,
           let history = frameHistory[clipID],
           let safe = history.bestFrame(around: time, preferredVersion: preferredHistoryVersion) {
            let diff = abs(safe.time - time)
            if diff <= allowedLead + epsilon {
                if let result = attemptSwap(buffer: safe.buffer,
                                            pts: safe.time,
                                            reason: "history") {
                    if result.1 {
                        AVSyncDiagnostics.shared.logSelection(
                            time: time,
                            clipID: clipID,
                            selectedPTS: safe.time,
                            nextPTS: nil,
                            valid: true
                        )
                    }
                    return result.0
                }
            }
        }

        if let lastPTS = lastDisplayedPTS[clipID],
           let lastBuffer = frameBuffer[clipID] {
            let videoFrameDur = max(videoFrameDuration(for: clipID), 1.0 / 120.0)
            let lowerBound = max(0, time - videoFrameDur * 2)
            let upperBound = max(lowerBound, time + videoFrameDur)
            let warmCount = warmFrameCount(for: clipID, in: lowerBound...upperBound)
            let historyEmpty = frameHistory[clipID]?.isEmpty ?? true
            guard warmCount == 0 && historyEmpty else {
                return nil
            }
            let ageMS = max((now - (lastSwapTime[clipID] ?? now)) * 1000.0, 0)
            ReverseScrubDiagnostics.shared.logDisplayFallback(clipID: clipID,
                                                               pts: lastPTS,
                                                               ageMS: ageMS,
                                                               reason: "no-buffer")
            ReverseScrubDiagnostics.shared.logWarmSequence(clipID: clipID,
                                                           targetPTS: time,
                                                           actualPTS: lastPTS,
                                                           warmTimes: [],
                                                           label: "fallback-cold")
            return lastBuffer
        }

        return nil
    }

    @MainActor
    func cacheFrame(_ frame: CVPixelBuffer,
                    clipID: UUID,
                    presentationTime: TimeInterval,
                    version: UInt64? = nil,
                    origin: FrameHistoryManager.Source = .playback,
                    storeInPrimary: Bool = true) {
        // DIAGNOSTIC: Log pixel buffer details at cache entry
        let format = CVPixelBufferGetPixelFormatType(frame)
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        print("[TRANSPORT_CACHE] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", presentationTime)) format=\(format) size=\(width)x\(height) primary=\(storeInPrimary)")
        
        let config = ScrubFeatureFlags.shared.config
        let sampleTime = latchedTime
        let lead = presentationTime - sampleTime
        let videoDuration = videoFrameDuration(for: clipID)
        let isScrubbingState = playbackState == .scrubbing
        let softFutureWindow: TimeInterval = {
            guard isScrubbingState else { return .infinity }
            let base = max(videoDuration * 4.0, 0.12)
            return min(base, 0.30)
        }()
        let hardFutureWindow: TimeInterval = {
            guard isScrubbingState else { return .infinity }
            let base = max(videoDuration * 12.0, softFutureWindow)
            return min(base, 0.60)
        }()

        var effectiveStoreInPrimary = storeInPrimary

        if isScrubbingState {
            let reverseAllowance = max(ScrubFeatureFlags.shared.config.reverseMaxPrimaryLead, 0.04)
            let primaryOK = lead >= -reverseAllowance
            if effectiveStoreInPrimary && !primaryOK {
                effectiveStoreInPrimary = false
                if isPlaybackDebugLoggingEnabled || origin == .scrub {
                    print("⬛️ [cacheFrame] late frame downgraded clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", presentationTime))s lead=\(String(format: "%.3f", lead))s")
                    lateFrameSkipCount += 1
                    print("[LATE_FRAME_SKIP] clip=\(clipID.uuidString.prefix(8)) count=\(lateFrameSkipCount) lead=\(String(format: "%.3f", lead))s")
                    let absMs = Int64((presentationTime * 1000.0).rounded())
                    Task { await SpotProxyManager.shared.recordLateFrame(clipID: clipID, absMs: absMs) }
                }
            }

            if lead > hardFutureWindow {
                if let timestamp = frameBufferTimestamps[clipID], timestamp > sampleTime + hardFutureWindow {
                    frameBuffer[clipID] = nil
                    frameBufferTimestamps[clipID] = nil
                }
                if isPlaybackDebugLoggingEnabled || origin == .scrub {
                    print("🚫 [cacheFrame] skip future frame clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", presentationTime))s lead=\(String(format: "%.3f", lead))s (hard cap)")
                }
                return
            }

            if lead > softFutureWindow && effectiveStoreInPrimary {
                effectiveStoreInPrimary = false
                if isPlaybackDebugLoggingEnabled || origin == .scrub {
                    print("⬛️ [cacheFrame] future frame downgraded clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", presentationTime))s lead=\(String(format: "%.3f", lead))s")
                }
            }
        }

        if effectiveStoreInPrimary {
            frameBuffer[clipID] = frame
            frameBufferTimestamps[clipID] = presentationTime
            if playbackState == .scrubbing {
                timelineTicker.resync(to: presentationTime)
            }
        } else if storeInPrimary, let timestamp = frameBufferTimestamps[clipID], timestamp - sampleTime > softFutureWindow {
            // If we previously latched a far-future primary frame, evict it so renderer doesn't see it.
            frameBuffer[clipID] = nil
            frameBufferTimestamps[clipID] = nil
        }

        let anchor = max(sampleTime, presentationTime)
        let manager: FrameHistoryManager
        if let existing = frameHistory[clipID] {
            manager = existing
        } else {
            let biasWindow = historyBiasWindow(for: clipID, cacheFrames: config.cacheBiasFrames)
            manager = FrameHistoryManager(byteBudget: config.cacheBytesBudget,
                                          maxAge: 15.0,
                                          biasWindow: biasWindow,
                                          scrubPriorityBoost: config.historyScrubPriorityBoost,
                                          byteWeight: config.historyByteWeight)
            frameHistory[clipID] = manager
        }
        manager.record(buffer: frame,
                       time: presentationTime,
                       version: version,
                       source: origin,
                       anchor: anchor)

        if origin == .scrub && ScrubFeatureFlags.shared.telemetryEnabled {
            let frameDuration = max(videoDuration, 1.0 / 120.0)
            let behindWindow = frameDuration * 4.0
            let aheadWindow = frameDuration * 1.5
            let lower = max(presentationTime - behindWindow, 0)
            let upper = presentationTime + aheadWindow
            let sampleRange = lower...upper
            let history = frameHistory[clipID]
            let historyCount = history?.count(in: sampleRange) ?? 0
            let bufferPTS = frameBufferTimestamps[clipID]
            var bufferContribution = 0
            if let bufferPTS, sampleRange.contains(bufferPTS) {
                let alreadyTracked = history?.contains(time: bufferPTS,
                                                       tolerance: frameDuration * 0.25) ?? false
                bufferContribution = alreadyTracked ? 0 : 1
            }
            let warmTimes = warmFrameTimes(for: clipID, in: sampleRange, limit: 6)
            let warmSummary = warmTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let bufferDesc = bufferPTS.map { String(format: "%.3f", $0) } ?? "nil"
            let windowDesc = String(format: "%.3f…%.3f", sampleRange.lowerBound, sampleRange.upperBound)
            let totalWarm = historyCount + bufferContribution
            print("[WARM_SNAPSHOT] clip=\(clipID.uuidString.prefix(8)) window=\(windowDesc) history=\(historyCount) buffer=\(bufferDesc) total=\(totalWarm) warm=[\(warmSummary)]")
        }

        if origin == .scrub, ScrubFeatureFlags.shared.telemetryEnabled {
            print("[CACHE_SCRUB] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", presentationTime)) lead=\(String(format: "%.3f", lead)) primary=\(effectiveStoreInPrimary ? "t" : "f")")
        }

        if origin == .scrub {
            ReverseScrubDiagnostics.shared.logColorMetadata(clipID: clipID,
                                                             pixelBuffer: frame,
                                                             pts: presentationTime)
        } else if effectiveStoreInPrimary {
            let primaryOK = lead >= -0.040
            if !primaryOK {
                effectiveStoreInPrimary = false
            }
        }

        if isScrubbingState, let history = frameHistory[clipID] {
            let reverseScrub = lead < -0.001
            let frameDuration = videoDuration
            let pastWindow: TimeInterval
            if reverseScrub {
                let baseFrames = max(config.reverseHistoryFrames, config.reverseLZFrames)
                let baseWindow = frameDuration * Double(max(baseFrames, 1))
                let slackWindow = abs(lead) + frameDuration * Double(max(config.reverseHistorySlackFrames, 1))
                let computed = max(baseWindow, slackWindow)
                pastWindow = min(max(computed, baseWindow), config.reverseHistoryMaxWindow)
            } else {
                let minForward = max(frameDuration * 3.0, 0.05)
                pastWindow = max(minForward, config.forwardHistoryWindow)
            }
            let pastCutoff = sampleTime - pastWindow
            if pastCutoff.isFinite {
                let removedPast = history.remove(before: pastCutoff)
                if removedPast > 0 {
                    ReverseScrubDiagnostics.shared.logHistoryTrim(clipID: clipID,
                                                                  direction: reverseScrub ? "reverse" : "forward",
                                                                  windowSeconds: pastWindow,
                                                                  removedCount: removedPast)
                }
            }
            let futureCutoff = sampleTime + hardFutureWindow
            if futureCutoff.isFinite {
                let removedFuture = history.remove(after: futureCutoff)
                if removedFuture > 0 {
                    ReverseScrubDiagnostics.shared.logHistoryTrim(clipID: clipID,
                                                                  direction: "future",
                                                                  windowSeconds: hardFutureWindow,
                                                                  removedCount: removedFuture)
                }
            }
        }

        // Always log scrub frames to debug decode success
        if origin == .scrub || (isPlaybackDebugLoggingEnabled && origin == .playback) {
            let versionStr = version.map { "v\($0)" } ?? "nil"
            print("💾 [cacheFrame] clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", presentationTime))s lead=\(String(format: "%.3f", lead))s version=\(versionStr) storeInPrimary=\(effectiveStoreInPrimary)")
        }

        // Note: We do NOT feed frame samples to the clock here!
        // presentationTime is the frame's timeline position, not the current playback time.
        // The clock should be driven by the ticker or audio, not by decoded frames.
    }

    private func pruneFrameCache(keepingUpTo cutoff: TimeInterval) {
        var removedIDs: [UUID] = []

        for (clipID, timestamp) in frameBufferTimestamps {
            let videoDuration = videoFrameDuration(for: clipID)
            let epsilon = max(videoDuration * 0.001, 1e-6)
            
            // CRITICAL FIX: Use SAME allowance as pixelBufferSync during scrubbing!
            // During scrubbing we need 1.0s allowance, not 0.7s
            let allowance: TimeInterval
            if isScrubbing {
                // Match scrubLeadAllowance from pixelBufferSync
                allowance = leadAllowance(for: clipID,
                                         framesAhead: 12.0,
                                         minimum: 0.35,
                                         maximum: 1.0)
            } else {
                // Normal pruning for playback/pause
                allowance = leadAllowance(for: clipID,
                                         framesAhead: 7.0,
                                         minimum: 0.24,
                                         maximum: 0.7)
            }

            if timestamp - cutoff > allowance + epsilon {
                frameBuffer[clipID] = nil
                frameBufferTimestamps[clipID] = nil
                removedIDs.append(clipID)
            }
        }

        var updatedHistory: [UUID: FrameHistoryManager] = [:]
        for (clipID, history) in frameHistory {
            var manager = history
            manager.prune(keepingNear: cutoff)
            if manager.latest() != nil {
                updatedHistory[clipID] = manager
            }
        }
        frameHistory = updatedHistory

        if !removedIDs.isEmpty {
            print("🧹 [Transport] Pruned future frames for clips: \(removedIDs) at cutoff=\(String(format: "%.3f", cutoff))s")
        }
    }

    private func cancelScrubCatchupTask() {
        scrubCatchupTask?.cancel()
        scrubCatchupTask = nil
        pendingScrubTime = nil
    }

    // DEPRECATED: Catch-up system removed - it always creates stale frames
    // Instead we rely on endScrub() deadline decode for exact frame
    private func scheduleScrubCatchup(after delay: TimeInterval,
                                      targetTime: TimeInterval,
                                      lastStamp: CFAbsoluteTime) {
        // NO-OP: Catch-up disabled
        // Reason: Catch-ups always arrive too late during active scrubbing
        // New scrubSeek calls cancel them before they run, or they run with stale version
        // Solution: Only decode exact frame when scrubbing ENDS (endScrub)
    }

    // Start continuous frame pre-buffering (ONLY for scrubbing)
    private func startFrameBuffering() {
        bufferUpdateTask?.cancel()
        bufferUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // ONLY run during scrubbing - TimelineTicker handles playback
                guard self.isScrubbing || self.playbackState != .playing else {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms idle sleep
                    continue
                }

                // CRITICAL FIX: Use latchedTime, NOT PlaybackClock during scrubbing!
                // PlaybackClock is paused and returns stale time during scrubbing
                let currentTime = self.latchedTime

                // Only update if time has changed
                if abs(currentTime - self.lastBufferUpdateTime) > 0.001 || self.frameBuffer.isEmpty {
                    self.lastBufferUpdateTime = currentTime
                    await self.scheduleFrameUpdate(at: currentTime, source: "frameBufferingLoop-scrub")
                }

                // Sleep 16ms for scrubbing responsiveness
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // CENTRAL FRAME UPDATE COORDINATOR - ONLY ONE UPDATE SOURCE
    private func scheduleFrameUpdate(at time: TimeInterval, source: String = "unknown", scrubVersion: UInt64? = nil) async {
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / 60.0  // 16.67ms for 60fps max

        // CRITICAL SOURCES: Always bypass throttling for UI-blocking operations
        let criticalSources = [
            "requestTime-sync",
            "requestPlay-preload",
            "requestPause-sync",
            "scrubEnd-sync",
            "videoSourcePrep"
        ]

        let isCriticalUpdate = criticalSources.contains(source)

        // CRITICAL FIX (Bug #14): Use per-source timestamp to prevent cross-source throttling
        // Example: frameBufferingLoop runs at t=100ms, scrubSeek runs at t=105ms
        // With shared timestamp: scrubSeek sees Δ=5ms → THROTTLED (WRONG!)
        // With per-source: scrubSeek sees Δ=20ms since last scrubSeek → ALLOWED (CORRECT!)
        let lastTime = lastUpdateFrameBufferTime[source] ?? 0
        let timeSinceLastUpdate = now - lastTime
        var shouldThrottle = !isCriticalUpdate && (timeSinceLastUpdate < minInterval)
        if ScrubFeatureFlags.stableReverseScrub && source == "scrubSeek" {
            shouldThrottle = false
        }

        // FOCUSED DEBUG: Only log scrubSeek throttling decisions
        if source == "scrubSeek" {
            let deltaMs = timeSinceLastUpdate * 1000.0
            if shouldThrottle {
                print("   ❌ THROTTLED: Δ=\(String(format: "%.1f", deltaMs))ms < \(String(format: "%.1f", minInterval * 1000))ms minimum")
                return
            } else {
                print("   ✅ ALLOWED: Δ=\(String(format: "%.1f", deltaMs))ms ≥ \(String(format: "%.1f", minInterval * 1000))ms minimum → PROCESSING")
                lastUpdateFrameBufferTime[source] = now
                await actuallyUpdateFrameBuffer(at: time, scrubVersion: scrubVersion)
            }
        } else {
            // Non-scrubSeek sources: minimal logging
            if shouldThrottle {
                return
            }
            lastUpdateFrameBufferTime[source] = now
            await actuallyUpdateFrameBuffer(at: time, scrubVersion: scrubVersion)
        }
    }

    private func actuallyUpdateFrameBuffer(at time: TimeInterval, scrubVersion: UInt64? = nil) async {
        // CRITICAL FIX A.1: Hard disable old pipeline when new scrub pipeline is active
        // This prevents double-pipeline conflicts and old throttling from blocking new pipeline
        if scrubPipelineEnabled {
            if ScrubFeatureFlags.shared.verboseLogging {
                print("🚫 [actuallyUpdateFrameBuffer] SKIPPED - new scrub pipeline active")
            }
            return
        }
        
        // Debug: Log entry
        if let scrubVersion = scrubVersion {
            print("🎬 [actuallyUpdateFrameBuffer] STARTING decode for t=\(String(format: "%.3f", time))s version=\(scrubVersion)")
        }
        
        // CRITICAL: Check version BEFORE starting expensive work
        if let scrubVersion = scrubVersion {
            let isStillCurrent = await MainActor.run { [weak self] in
                self?.currentFrameUpdateVersion == scrubVersion
            }
            guard isStillCurrent else {
                let currentVersion = await MainActor.run { [weak self] in self?.currentFrameUpdateVersion ?? 0 }
                print("🚫 [actuallyUpdateFrameBuffer] ABORTING - scrub version \(scrubVersion) is stale (current: \(currentVersion)) BEFORE decode")
                return
            }
        }
        
        let segments = compositeSegments(at: time)
        let slice = compositeSlice(at: time)

        let halfFrame = max(frameDuration * 0.5, 1e-6)

        // DEBUG: Log actual timing behavior
        debugFrameCount += 1

        if time - debugLastLogTime >= 1.0 || debugFrameCount % 60 == 0 {
            let duration = max(time - debugLastLogTime, 0.001)
            let fps = Double(debugFrameCount) / duration
            print("🔥 [DEBUG] updateFrameBuffer: frame \(debugFrameCount), time=\(String(format: "%.3f", time))s, rate=\(String(format: "%.1f", fps))fps, frameDuration=\(String(format: "%.4f", frameDuration))s")
            debugLastLogTime = time
            debugFrameCount = 0  // Reset frame count after logging
        }

        let sampleTime: TimeInterval
        if let slice {
            // FRAME-ACCURATE: Use exact time, NO lookahead offset!
            // The old logic added +halfFrame for buffering, but that causes
            // playback to run too fast because it samples future frames
            sampleTime = max(slice.start, min(time, slice.end))
        } else {
            sampleTime = time
        }

        var clipsByID: [UUID: Clip] = [:]
        for segment in segments {
            if let clip = segment.clip {
                clipsByID[clip.id] = clip
            }
        }
        if let slice {
            for attachment in slice.mattes.values {
                clipsByID[attachment.clip.id] = attachment.clip
            }
        }

        guard !clipsByID.isEmpty else { return }

        // During scrubbing we still perform direct requests so results are immediately available
        await withTaskGroup(of: (UUID, CVPixelBuffer?, TimeInterval).self) { group in
            for clip in clipsByID.values {
                guard let source = videoSources[clip.id] else { continue }

                group.addTask {
                    guard !Task.isCancelled else { return (clip.id, nil, sampleTime) }

                    // Always decode at exact requested time
                    if let decoded = try? await source.copyFrame(at: sampleTime,
                                                                   caller: "updateFrameBuffer",
                                                                   version: scrubVersion) {
                        return (clip.id, decoded.pixelBuffer, decoded.timelineTime)
                    }

                    // Fallback: use last decoded frame if available
                    if let cached = await source.latestFrame() {
                        return (clip.id, cached.pixelBuffer, cached.timelineTime)
                    }
                    return (clip.id, nil, sampleTime)
                }
            }

            for await (clipID, frame, ts) in group {
                guard !Task.isCancelled, let frame else { continue }

                // CRITICAL FIX (Bug #13): Check if this scrubSeek version is still current!
                // If user scrubbed again while this task was loading frames, DON'T cache old frames!
                // Example: scrubSeek(5.0s) v1 loading → scrubSeek(4.8s) v2 starts → v1 finishes
                //          v1 should NOT cache frame at 5.0s because v2 is now current!
                //
                // LAGGY SCRUB FIX: Allow frames that are max 2 versions old
                // Problem: Decode takes ~100ms, but scrub events come every 33ms
                // Result: Frame is "stale" by the time it's ready (3 versions behind)
                // Solution: Accept frames that are 1-2 versions old (still useful!)
                if let scrubVersion = scrubVersion {
                    let currentVersion = await MainActor.run { [weak self] in
                        self?.currentFrameUpdateVersion ?? 0
                    }
                    let versionDelta = currentVersion > scrubVersion ? currentVersion - scrubVersion : 0
                    
                    // Allow frames that are max 2 versions old
                    // This gives decode ~66ms (2 * 33ms) to complete
                    guard versionDelta <= 2 else {
                        print("🚫 [actuallyUpdateFrameBuffer] SKIPPING cache - scrub version \(scrubVersion) is stale (current: \(currentVersion), delta: \(versionDelta))")
                        // Still store in history for potential reuse, but not in primary buffer
                        await MainActor.run { [weak self] in
                            self?.cacheFrame(frame,
                                             clipID: clipID,
                                             presentationTime: ts,
                                             version: scrubVersion,
                                             origin: .scrub,
                                             storeInPrimary: false)
                        }
                        continue
                    }
                    
                    // Frame is recent enough - log if it's slightly old
                    if versionDelta > 0 {
                        print("⚠️ [actuallyUpdateFrameBuffer] Using slightly old frame - version \(scrubVersion) (current: \(currentVersion), delta: \(versionDelta))")
                    }
                }

                await MainActor.run { [weak self] in
                    let origin: FrameHistoryManager.Source = scrubVersion == nil ? .playback : .scrub
                    self?.cacheFrame(frame,
                                     clipID: clipID,
                                     presentationTime: ts,
                                     version: scrubVersion,
                                     origin: origin)
                }
            }
        }
    }

    func requestPlay(rate: Double, completion: ((Bool) -> Void)?) {
        print("🎯 [DEBUG] requestPlay called with rate=\(rate)")
        let clamped = clampTimelineTime(latchedTime)
        guard let (index, segment) = segment(at: clamped) else {
            latchedPlaybackRate = 0
            print("🛑 [DEBUG] requestPlay() no segment found - setting playbackState = .paused")
            playbackState = .paused
            monotonicGuardEnabled = false
            uiWantsPlay = false
            stopTimelineTicker()
            logTransportState(event: "requestPlay", note: "no segment", timelineTime: clamped, wasGap: true)
            completion?(false)
            return
        }

        latchedTime = clamped
        playbackState = .playing
        uiWantsPlay = true
        monotonicGuardEnabled = true
        currentSegmentIndex = index
        latchedPlaybackRate = rate
        currentCompositeSliceIndex = compositeSliceIndex(for: clamped)

        // CRITICAL: Ensure initial frame is loaded BEFORE starting playback
        // This prevents black/gray frames at playback start (especially at time 0.0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scheduleFrameUpdate(at: clamped, source: "requestPlay-preload")
        }

        if let clip = segment.clip {
            stopGapTimer()
            isGapActive = false
            logTransportState(event: "play", note: clip.assetRef, timelineTime: clamped, wasGap: false)
            completion?(true)
        } else {
            // Start gap timer for smooth playback through gaps
            startGapTimer(for: segment, startingAt: max(segment.start, clamped))
            logTransportState(event: "play-gap", note: "gap", timelineTime: clamped, wasGap: true)
            // PlaybackClock controlled by TimelineTicker (started below)
            completion?(true)
        }

        updateAudioForCurrentTime(playing: true, force: true)

        // Stop frame buffering - TimelineTicker will drive frame requests during playback
        bufferUpdateTask?.cancel()
        bufferUpdateTask = nil

        // CRITICAL FIX: Start ticker IMMEDIATELY, don't wait for frame warmup
        // After Effects behavior: Timeline starts moving immediately, frames load in background
        startTimelineTicker(from: latchedTime, rate: rate)
        print("🎯 [DEBUG] requestPlay() - Ticker started immediately")

        // Load warmup frame in background (non-blocking)
        tickerWarmupTask?.cancel()
        if let clip = segment.clip,
           let source = videoSources[clip.id] {
            let warmupTime = clamped
            let clipID = clip.id

            tickerWarmupTask = Task { [weak self] in
                guard let self else { return }
                // Load first frame asynchronously - ticker already running
                if let frame = try? await source.copyFrame(at: warmupTime, caller: "tickerWarmup") {
                    await MainActor.run { [weak self] in
                        self?.cacheFrame(frame.pixelBuffer,
                                         clipID: clipID,
                                         presentationTime: frame.timelineTime,
                                         origin: .playback)
                    }
                } else if let latest = await source.latestFrame() {
                    await MainActor.run { [weak self] in
                        self?.cacheFrame(latest.pixelBuffer,
                                         clipID: clipID,
                                         presentationTime: latest.timelineTime,
                                         origin: .playback)
                    }
                }
            }
        }

        // Schedule initial frame update
        Task { [weak self] in
            await self?.scheduleFrameUpdate(at: clamped, source: "requestPlay-initial")
        }

        // PlaybackClock is now controlled by TimelineTicker
        print("🎯 [DEBUG] requestPlay() - PlaybackClock controlled by TimelineTicker")
    }

    func requestPause() {
        print("🛑 [DEBUG] requestPause() called")
        let pauseTime = latchedTime
        playbackState = .paused
        monotonicGuardEnabled = false
        uiWantsPlay = false
        latchedPlaybackRate = 0
        isTransitioningSegments = false
        stopTimelineTicker()

        // CRITICAL FIX (Bug #12): Cancel ALL frame loading tasks!
        // During playback, scheduleActiveClipFrame runs async and loads future frames
        // If user pauses and then scrubs, old tasks finish and overwrite cache with WRONG frames
        // Example: Playing at 3.9s, tasks loading 3.5s, 3.6s, 3.7s, 3.8s, 3.9s
        //          User pauses and scrubs to 3.4s (backward)
        //          Old tasks finish and cache has frames 3.5s-3.9s → WRONG!
        bufferUpdateTask?.cancel()
        bufferUpdateTask = nil
        activeClipFrameTask?.cancel()
        activeClipFrameTask = nil
        cancelScrubCatchupTask()
        pruneFrameCache(keepingUpTo: pauseTime)
        // Keep frame buffer - don't clear it! Shows last frame instead of black
        // frameBuffer.removeAll()
        // frameBufferTimestamps.removeAll()
        audioMixer.pauseAll()

        if let segment = currentSegment, segment.clip == nil {
            stopGapTimer(disableOverlay: false)
            isGapActive = true
            audioMixer.setMuted(true)
        } else {
            stopGapTimer()
        }

        logTransportState(event: "pause", note: "user", timelineTime: latchedTime, wasGap: isGapActive)
        playbackClock.pause(at: latchedTime)

        // Load frame at pause position to ensure correct frame is shown
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scheduleFrameUpdate(at: pauseTime, source: "requestPause-sync")
        }
    }

    func requestTime(_ time: TimeInterval, completion: ((Bool) -> Void)?) {
        let clamped = clampTimelineTime(time)
        print("🛑 [DEBUG] requestTime() setting playbackState = .paused")
        playbackState = .paused
        uiWantsPlay = false
        monotonicGuardEnabled = false
        latchedPlaybackRate = 0
        isTransitioningSegments = false
        stopGapTimer(disableOverlay: false)
        stopTimelineTicker()

        applyDirectTime(clamped)
        audioMixer.seek(to: clamped)
        updateAudioForCurrentTime(playing: false, force: true)
        timelineTicker.seek(to: clamped)
        playbackClock.pause(at: clamped)

        // After Effects behavior: Ensure frame is loaded before signaling completion
        // This prevents UI from showing black/gray frames during timeline navigation
        Task { @MainActor [weak self] in
            guard let self else {
                completion?(false)
                return
            }

            // Load frame for the requested time
            await self.scheduleFrameUpdate(at: clamped, source: "requestTime-sync")

            // Small delay to ensure frame is rendered (1-2 frame durations)
            let delayNs: UInt64 = UInt64(max(self.frameDuration * 1.5, 0.033) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)

            // Now signal completion - frame should be visible
            completion?(true)
        }
    }

    func beginScrub() {
        print("🟡 [SCRUB START] ============================================")
        scrubSeekCallCount = 0  // Reset counter
        lastScrubSeekTime = CFAbsoluteTimeGetCurrent()
        lastScrubTime = latchedTime  // Initialize for velocity calculation

        resumeAfterScrub = playbackState == .playing && uiWantsPlay && abs(latchedPlaybackRate) > 1e-6
        scrubResumeRate = abs(latchedPlaybackRate) > 1e-6 ? latchedPlaybackRate : 1.0
        playbackState = .scrubbing
        uiWantsPlay = false
        monotonicGuardEnabled = false
        latchedPlaybackRate = 0
        isScrubbing = true
        isTransitioningSegments = false

        // CRITICAL FIX: Cancel ALL async tasks before scrubbing
        tickerWarmupTask?.cancel()
        tickerWarmupTask = nil
        activeClipFrameTask?.cancel()
        activeClipFrameTask = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        bufferUpdateTask?.cancel()
        bufferUpdateTask = nil
        cancelScrubCatchupTask()
        pruneFrameCache(keepingUpTo: latchedTime)
        clipPrimedForDisplay.removeAll()

        stopGapTimer(disableOverlay: false)
        stopTimelineTicker()
        logTransportState(event: "beginScrub", note: "", timelineTime: latchedTime, wasGap: currentSegment?.clip == nil)

        // CRITICAL FIX (Bug #14 Part 2): DON'T start frameBufferingLoop during scrubbing!
        // scrubSeek() already loads frames at throttled 60fps via actuallyUpdateFrameBuffer()
        // Starting frameBufferingLoop here causes PARALLEL frame loading:
        //   - scrubSeek() → 60fps (throttled)
        //   - frameBufferingLoop → unlimited fps (detects latchedTime changes)
        //   - TOTAL: ~120fps → MainActor freeze!
        // frameBufferingLoop is only needed for passive states (paused/stopped), not active scrubbing
        // stopFrameBuffering()  // Already stopped in previous lines via task cancellations

        playbackClock.pause(at: latchedTime)
        
        // Phase 3 + Phase 2: Start integrated scrub pipeline
        if scrubPipelineEnabled {
            if integratedScrubPipeline == nil {
                integratedScrubPipeline = IntegratedScrubPipeline()
            }
            Task { [weak self] in
                guard let self else { return }
                let visibleClips = await self.getVisibleClipsWithAssets(at: latchedTime)
                await self.integratedScrubPipeline?.beginScrub(clips: visibleClips)
                await MainActor.run {
                    print("✨ [INTEGRATED_PIPELINE] Started with \(visibleClips.count) clips")
                }
            }
        } else {
            // OLD: Use legacy scrub coordinator
            let visibleClips = getVisibleClips(at: latchedTime)
            scrubCoordinator.beginScrub(at: latchedTime, clips: visibleClips)
        }
    }
    
    /// Gets all visible clips at the specified time with their VideoSource instances (legacy)
    private func getVisibleClips(at time: TimeInterval) -> [UUID: VideoSource] {
        var clips: [UUID: VideoSource] = [:]
        
        // Get all segments at current time
        let segments = compositeSegments(at: time)
        for segment in segments {
            if let clip = segment.clip, let source = videoSources[clip.id] {
                clips[clip.id] = source
            }
        }
        
        // Also include composite slice mattes
        if let slice = compositeSlice(at: time) {
            for attachment in slice.mattes.values {
                if let source = videoSources[attachment.clip.id] {
                    clips[attachment.clip.id] = source
                }
            }
        }
        
        return clips
    }
    
    /// Gets all visible clips with AVAsset and AVAssetTrack for integrated pipeline
    private func getVisibleClipsWithAssets(at time: TimeInterval) async -> [UUID: (asset: AVAsset, track: AVAssetTrack)] {
        var clips: [UUID: (asset: AVAsset, track: AVAssetTrack)] = [:]
        
        // Get all segments at current time
        let segments = compositeSegments(at: time)
        for segment in segments {
            if let clip = segment.clip, let source = videoSources[clip.id] {
                let asset = source.asset
                if let track = await source.videoTrack {
                    clips[clip.id] = (asset, track)
                }
            }
        }
        
        // Also include composite slice mattes
        if let slice = compositeSlice(at: time) {
            for attachment in slice.mattes.values {
                if let source = videoSources[attachment.clip.id] {
                    let asset = source.asset
                    if let track = await source.videoTrack {
                        clips[attachment.clip.id] = (asset, track)
                    }
                }
            }
        }
        
        return clips
    }

    // DEBUG: Track scrubSeek timing
    private var scrubSeekCallCount: Int = 0
    private var lastScrubSeekTime: CFAbsoluteTime = 0
    private var lastScrubTime: TimeInterval = 0

    func scrubSeek(to time: TimeInterval) {
        let now = CFAbsoluteTimeGetCurrent()
        let deltaMs = (now - lastScrubSeekTime) * 1000.0
        scrubSeekCallCount += 1

        print("🔴 [scrubSeek #\(scrubSeekCallCount)] time=\(String(format: "%.3f", time))s, Δ=\(String(format: "%.1f", deltaMs))ms since last call")

        let clamped = clampTimelineTime(time)
        
        // Calculate velocity for scrub coordinator (frames per second)
        // velocity = (timeline distance) / (real time elapsed)
        // Negative velocity = reverse scrubbing
        let timeDelta = clamped - lastScrubTime
        let realTimeDelta = max(now - lastScrubSeekTime, 0.001)  // Avoid division by zero
        let velocity = timeDelta / realTimeDelta  // timeline seconds per real second
        
        // CRITICAL FIX (Bug #14 Part 5): Update latchedTime BEFORE throttling!
        // This ensures MetalRenderer always shows the current scrub position (60fps visual update)
        // Even when frame decoding is throttled to 30fps, the video position indicator stays smooth
        // This is now safe because we removed the `playhead` parameter from TimelineTrackLane (Part 4)
        // which prevented the expensive Timeline UI re-renders
        applyDirectTime(clamped)

        // CRITICAL FIX (Bug #14): SYNCHRONOUS throttling check BEFORE starting async task!
        // Race condition if checked in scheduleFrameUpdate: Multiple tasks start in parallel,
        // all check timestamp before any sets it → all ALLOWED → 100+ parallel tasks → FREEZE!
        //
        // ADAPTIVE THROTTLING FIX: No throttling during fast scrubbing!
        // Problem: 28ms throttle = only process every 2nd frame at 60fps (16.7ms) → flickering!
        // Solution: Use VELOCITY to detect fast scrubbing (not timeDelta which is always small at 60fps!)
        let velocityAbs = abs(velocity)
        let isFastScrubbing = velocityAbs > 1.0  // Moving >1 fps = fast scrub (e.g. -3.6 fps)
        
        var minInterval: TimeInterval = isFastScrubbing ? 0.0 : 0.028  // No throttle when fast!
        if ScrubFeatureFlags.stableReverseScrub {
            minInterval = 0.0
        }
        
        let throttleSlack = 0.001   // 1ms jitter tolerance
        let lastTime = lastUpdateFrameBufferTime["scrubSeek"] ?? 0
        let timeSinceLastUpdate = now - lastTime

        if timeSinceLastUpdate + throttleSlack < minInterval {
            let deltaMs = timeSinceLastUpdate * 1000.0
            // Minimal logging - only show every 10th throttle to reduce log spam
            if scrubSeekCallCount % 10 == 0 {
                print("   ❌ THROTTLED: Δ=\(String(format: "%.1f", deltaMs))ms < \(String(format: "%.1f", minInterval * 1000))ms minimum")
            }
            
            // CRITICAL FIX: NO catch-up scheduling during active scrubbing!
            // Catch-ups always arrive too late and create stale frames.
            // Instead: Only load exact frame when scrubbing ENDS (endScrub deadline decode)
            
            lastScrubSeekTime = now
            // Still update velocity tracking even when throttled
            lastScrubTime = clamped
            scrubCoordinator.updateScrub(at: clamped, velocity: velocity)
            return
        }

        // ALLOWED: Update timestamp NOW (synchronously, before async task)
        lastUpdateFrameBufferTime["scrubSeek"] = now
        lastScrubSeekTime = now
        lastScrubTime = clamped
        print("   ✅ ALLOWED: Δ=\(String(format: "%.1f", timeSinceLastUpdate * 1000))ms ≥ \(String(format: "%.1f", minInterval * 1000))ms → PROCESSING (fast=\(isFastScrubbing), version \(scrubSeekVersion + 1))")
        
        // PREDICTIVE DECODING: DISABLED - causes frames to be too far ahead!
        // Problem: Frames are decoded 100-300ms ahead, but MetalRenderer needs current frame
        // Solution: Decode at CURRENT position, not predicted
        let clampedPredicted = clamped  // NO prediction!
        
        // Phase 3 + Phase 2: Update integrated pipeline
        if scrubPipelineEnabled {
            let direction: ScrubCoordinator.ScrubDirection = velocity < 0 ? .reverse : .forward
            Task {
                await integratedScrubPipeline?.updateScrub(
                    tNow: clampedPredicted,  // Use PREDICTED time!
                    velocity: velocity,
                    direction: direction
                )
            }
            // CRITICAL: Don't run actuallyUpdateFrameBuffer when new pipeline is active!
            // The integrated pipeline has its own admission control and decode logic
            return
        }
        
        // OLD: Update legacy coordinator
        scrubCoordinator.updateScrub(at: clamped, velocity: velocity)

        // Version-based caching
        scrubSeekVersion += 1
        currentFrameUpdateVersion = scrubSeekVersion
        let thisVersion = scrubSeekVersion
        pendingScrubTime = nil

        // Start async task with PREDICTED time (OLD PIPELINE ONLY)
        Task { [weak self] in
            await self?.actuallyUpdateFrameBuffer(at: clampedPredicted, scrubVersion: thisVersion)
        }
        
        // Don't track task - let it run to completion
        // scrubSeekTask is only used for cleanup in endScrub
    }

    func endScrub(resumeIfWanted: Bool) {
        print("🟢 [SCRUB END] Total scrubSeek calls: \(scrubSeekCallCount) ============")
        isScrubbing = false

        // Note: We don't cancel scrubSeek tasks anymore - they run to completion
        // Version check will discard stale frames
        // scrubSeekTask?.cancel()  // REMOVED
        scrubSeekTask = nil
        cancelScrubCatchupTask()

        // After Effects behavior: Load exact frame when scrubbing ends
        let finalTime = latchedTime
        
        // CRITICAL: Increment version to invalidate any in-flight scrubSeek decodes
        scrubSeekVersion &+= 1
        currentFrameUpdateVersion = scrubSeekVersion
        
        // Phase 3 + Phase 2: End integrated pipeline with deadline decode
        if scrubPipelineEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                print("⏱️ [endScrub] Starting deadline decode for exact frame at t=\(String(format: "%.3f", finalTime))s")
                let deadlineStart = CFAbsoluteTimeGetCurrent()
                
                // Perform deadline decode via integrated pipeline (ungated, high priority)
                await self.integratedScrubPipeline?.endScrub(tFinal: finalTime)
                
                let deadlineDuration = (CFAbsoluteTimeGetCurrent() - deadlineStart) * 1000
                print("✅ [endScrub] Deadline decode completed in \(String(format: "%.1f", deadlineDuration))ms")
                print("✨ [INTEGRATED_PIPELINE] Ended at t=\(String(format: "%.3f", finalTime))s")
            }
        } else {
            // OLD: Use legacy coordinator
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                print("⏱️ [endScrub] Starting deadline decode for exact frame at t=\(String(format: "%.3f", finalTime))s")
                let deadlineStart = CFAbsoluteTimeGetCurrent()
                
                // Perform deadline decode via coordinator (ungated, high priority)
                await self.scrubCoordinator.endScrub(at: finalTime)
                
                let deadlineDuration = (CFAbsoluteTimeGetCurrent() - deadlineStart) * 1000
                print("✅ [endScrub] Deadline decode completed in \(String(format: "%.1f", deadlineDuration))ms")
            }
        }

        // CRITICAL FIX: Clear resumeAfterScrub IMMEDIATELY to prevent race conditions
        let shouldResume = resumeIfWanted && resumeAfterScrub
        resumeAfterScrub = false

        if shouldResume {
            let rate = scrubResumeRate
            latchedPlaybackRate = rate
            requestPlay(rate: rate, completion: nil)
        } else {
            playbackState = .paused
            monotonicGuardEnabled = false
            uiWantsPlay = false
            latchedPlaybackRate = 0
            stopGapTimer(disableOverlay: false)

            // Stop frame buffering when scrub ends without resuming
            bufferUpdateTask?.cancel()
            bufferUpdateTask = nil

            // Load exact frame synchronously after scrubbing ends
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.scheduleFrameUpdate(at: finalTime, source: "scrubEnd-sync")
            }
        }

        // Note: resumeAfterScrub already cleared at line 566 to prevent race conditions
        logTransportState(event: "endScrub", note: shouldResume ? "resume" : "stayPaused", timelineTime: latchedTime, wasGap: currentSegment?.clip == nil)
        playbackClock.align(to: latchedTime)
    }

    func setTimelineDuration(_ duration: TimeInterval) {
        let resolved = max(0, duration)
        playbackGraph.duration = max(resolved, playbackGraph.segments.last?.end ?? resolved)
        if latchedTime > playbackGraph.duration {
            latchedTime = playbackGraph.duration
            playbackClock.align(to: latchedTime)
        }
    }

    func updateTimelineSegments(_ segments: [TimelineSegment]) {
        applyPlaybackTimeline(segments,
                              duration: playbackGraph.duration,
                              compositeSlices: playbackGraph.compositeSlices)
    }

    private func applyPlaybackTimeline(_ segments: [TimelineSegment],
                                       duration: TimeInterval,
                                       compositeSlices: [TimelineCompositeSlice]) {
        let sorted = segments.sorted { $0.start < $1.start }
        let maxEnd = sorted.last?.end ?? 0
        let resolvedDuration = max(duration, maxEnd)
        let nextVersion = playbackGraph.version &+ 1

        playbackGraph = TransportPlaybackGraph(version: nextVersion,
                                               segments: sorted,
                                               duration: resolvedDuration,
                                               compositeSlices: compositeSlices)

        currentCompositeSliceIndex = compositeSliceIndex(for: latchedTime)
        audioMixer.reset()

        if !compositeWarningLogged,
           compositeSlices.contains(where: { $0.orderedSegments.count > 1 }) {
            compositeWarningLogged = true
            let stackedCount = compositeSlices.filter { $0.orderedSegments.count > 1 }.count
            print("[Transport] detected \(stackedCount) multi-layer timeline slices (audio mixer engaged)")
        }

        stopGapTimer()
        gapTelemetryMarked = false
        lastPreloadCheckTime = 0
        let clamped = clampTimelineTime(latchedTime)
        latchedTime = clamped

        if let (idx, segment) = segment(at: clamped) {
            currentSegmentIndex = idx
            if segment.clip == nil {
                latchedTime = segment.start
                isGapActive = true
                audioMixer.setMuted(true)
            } else {
                isGapActive = false
                audioMixer.setMuted(desiredAudioMute)
            }
        } else {
            currentSegmentIndex = nil
            latchedTime = playbackGraph.duration
            isGapActive = false
            audioMixer.setMuted(desiredAudioMute)
        }

        // Always reset state - caller will handle resuming if needed
        playbackState = .paused
        latchedPlaybackRate = 0
        monotonicGuardEnabled = false
        uiWantsPlay = false
        resumeAfterScrub = false
        isTransitioningSegments = false
        preparedClipSegmentIndex = nil
        preparingClipSegmentIndex = nil
        compositeWarningLogged = false

        logTransportState(event: "applyGraph", note: "v=\(playbackGraph.version)", timelineTime: latchedTime, wasGap: isGapActive)
        playbackClock.pause(at: latchedTime)
    }

    private func updateDirtyRegions(for composition: Composition) {
        let canvas = currentCanvasSize()
        let layers = mediaLayers(from: composition)

        if layers.isEmpty {
            let update = BackScrubbingIntegration.dirtyTracker.markAllDirty(compID: compositionID,
                                                                            canvasSize: canvas,
                                                                            reason: "composition-empty")
            Task { await FrameServer.shared.applyDirtyUpdate(update) }
            addDirtyRegion(update.region)
            return
        }

        if let update = BackScrubbingIntegration.dirtyTracker.update(compID: compositionID,
                                                                      canvasSize: canvas,
                                                                      layers: layers,
                                                                      reason: "composition-update") {
            Task { await FrameServer.shared.applyDirtyUpdate(update) }
            addDirtyRegion(update.region)
        }
    }

    private func mediaLayers(from composition: Composition) -> [MediaLayer] {
        var latestClipByLayer: [UUID: Clip] = [:]
        for clip in composition.clips {
            let layerID = clip.transformRef ?? clip.id
            if let existing = latestClipByLayer[layerID] {
                if clip.dstStart >= existing.dstStart {
                    latestClipByLayer[layerID] = clip
                }
            } else {
                latestClipByLayer[layerID] = clip
            }
        }

        var result: [MediaLayer] = []
        result.reserveCapacity(latestClipByLayer.count)

        for (layerID, clip) in latestClipByLayer {
            let track = composition.tracks.first(where: { $0.id == layerID })
            let trackBlend = track?.blendMode ?? .normal
            let layerName = track?.name ?? clip.name
            let size = mediaSize(for: clip)
            let mediaSizeVec = SIMD2<Float>(Float(size.width), Float(size.height))
            let layer = MediaLayer(id: layerID,
                                   name: layerName,
                                   mediaSize: mediaSizeVec,
                                   transform: clip.transform,
                                   enabled: clip.enabled,
                                   blendMode: trackBlend)
            result.append(layer)
        }

        return result
    }

    private func mediaSize(for clip: Clip) -> CGSize {
        if let widthString = clip.metadata.userMetadata["videoWidth"],
           let heightString = clip.metadata.userMetadata["videoHeight"],
           let width = Double(widthString),
           let height = Double(heightString),
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }

        if let size = clipNaturalSizes[clip.id], size.width > 0, size.height > 0 {
            return size
        }

        return defaultCanvasSize
    }

    private func currentCanvasSize() -> CGSize {
        if canvasSize.width <= 0 || canvasSize.height <= 0 {
            return defaultCanvasSize
        }
        return canvasSize
    }

    @objc private func canvasSizeChanged(_ notification: Notification) {
        guard let size = notification.userInfo?["size"] as? CGSize,
              size.width > 0,
              size.height > 0 else { return }
        canvasSize = size
        let update = BackScrubbingIntegration.dirtyTracker.markAllDirty(compID: compositionID,
                                                                        canvasSize: size,
                                                                        reason: "canvas-size-changed")
        Task { await FrameServer.shared.applyDirtyUpdate(update) }
        addDirtyRegion(update.region)
    }

    func consumeDirtyRects() -> [CGRect] {
        if pendingDirtyTiles.isEmpty {
            return []
        }
        let tiles = pendingDirtyTiles
        pendingDirtyTiles.removeAll()
        Task { _ = await FrameServer.shared.consumeDirtyRects(for: compositionID) }
        return tiles.map { tileRect(for: $0) }
    }

    private func addDirtyRegion(_ rect: CGRect) {
        let indices = tileIndices(for: rect)
        guard !indices.isEmpty else { return }
        pendingDirtyTiles.formUnion(indices)
    }

    private func alignToTileGrid(_ rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .null }
        let tile = renderTileSize
        let minX = floor(rect.minX / tile) * tile
        let minY = floor(rect.minY / tile) * tile
        let maxX = ceil(rect.maxX / tile) * tile
        let maxY = ceil(rect.maxY / tile) * tile
        return CGRect(x: minX,
                      y: minY,
                      width: max(maxX - minX, tile),
                      height: max(maxY - minY, tile))
    }

    private func tileRect(for index: TileIndex) -> CGRect {
        let origin = CGPoint(x: CGFloat(index.x) * renderTileSize,
                             y: CGFloat(index.y) * renderTileSize)
        return CGRect(origin: origin,
                      size: CGSize(width: renderTileSize, height: renderTileSize))
    }

    private func tileIndices(for rect: CGRect) -> Set<TileIndex> {
        let aligned = alignToTileGrid(rect)
        guard aligned.width > 0, aligned.height > 0 else { return [] }

        let minX = Int(floor(aligned.minX / renderTileSize))
        let maxX = Int(ceil(aligned.maxX / renderTileSize)) - 1
        let minY = Int(floor(aligned.minY / renderTileSize))
        let maxY = Int(ceil(aligned.maxY / renderTileSize)) - 1

        guard maxX >= minX, maxY >= minY else { return [] }

        var result: Set<TileIndex> = []
        for x in minX...maxX {
            for y in minY...maxY {
                result.insert(TileIndex(x: x, y: y))
            }
        }
        return result
    }


    private func logTransportState(event: String,
                                   note: String,
                                   timelineTime: TimeInterval,
                                   wasGap: Bool) {
        let stateDescription: String
        switch playbackState {
        case .paused: stateDescription = "paused"
        case .playing: stateDescription = "playing"
        case .scrubbing: stateDescription = "scrubbing"
        }

        let message = String(
            format: "transport|%@|t=%.3f|rate=%.3f|state=%@|uiWantsPlay=%@|graph=%d|gap=%@|note=%@",
            event,
            timelineTime,
            latchedPlaybackRate,
            stateDescription,
            uiWantsPlay ? "1" : "0",
            playbackGraph.version,
            wasGap ? "1" : "0",
            note
        )
        guard transportTraceEnabled else { return }
        print(message)
    }

    private var debugLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["CIN_TRANSPORT_DEBUG"] == "1"
    }

    private var transportTraceEnabled: Bool {
        ProcessInfo.processInfo.environment["CIN_TRANSPORT_TRACE"] == "1"
    }

    private func preloadNextSegment() {
        guard let currentIndex = currentSegmentIndex else { return }
        prepareNextClipIfNeeded(after: currentIndex)
    }

    private func segment(at time: TimeInterval) -> (Int, TimelineSegment)? {
        for (index, segment) in playbackGraph.segments.enumerated() {
            if time >= segment.start - 1e-6 && time < segment.end + 1e-6 {
                return (index, segment)
            }
        }
        return nil
    }

    private func advanceToNextSegment() {
        guard let currentIndex = currentSegmentIndex else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < playbackGraph.segments.count else {
            latchedPlaybackRate = 0
            stopGapTimer()
            print("🛑 [DEBUG] advanceToNextSegment() reached end - setting playbackState = .paused")
            playbackState = .paused
            monotonicGuardEnabled = false
            uiWantsPlay = false
            stopTimelineTicker()
            logTransportState(event: "segment-end", note: "end of graph", timelineTime: playbackGraph.duration, wasGap: false)
            return
        }

        stopGapTimer()
        let nextSegment = playbackGraph.segments[nextIndex]
        currentSegmentIndex = nextIndex
        currentCompositeSliceIndex = compositeSliceIndex(for: nextSegment.start)
        if let clip = nextSegment.clip {
            isGapActive = false
            gapTelemetryMarked = false

            let targetTime = clampTimelineTime(nextSegment.start)
            latchedTime = targetTime

            if preparedClipSegmentIndex == nextIndex {
                preparedClipSegmentIndex = nil
                preparingClipSegmentIndex = nil
                isTransitioningSegments = false
            } else {
                // Mark that we're transitioning to avoid monotonic guard blocking
                isTransitioningSegments = true
                preparedClipSegmentIndex = nil
                preparingClipSegmentIndex = nil

                Task { [weak self] in
                    guard let self else { return }
                    await self.scheduleFrameUpdate(at: targetTime, source: "segmentTransition")
                    await MainActor.run { [weak self] in
                        self?.isTransitioningSegments = false
                    }
                }
            }
        } else {
            if latchedPlaybackRate != 0 {
                startGapTimer(for: nextSegment, startingAt: nextSegment.start)
            }
            latchedTime = clampTimelineTime(nextSegment.start)
            isGapActive = true
        }

        updateAudioForCurrentTime(playing: playbackState == .playing && latchedPlaybackRate != 0, force: true)
        playbackClock.align(to: latchedTime)
    }

    private var currentSegment: TimelineSegment? {
        guard let index = currentSegmentIndex, index < playbackGraph.segments.count else { return nil }
        return playbackGraph.segments[index]
    }

    private func clampTimelineTime(_ time: TimeInterval) -> TimeInterval {
        let limit = max(playbackGraph.duration, playbackGraph.segments.last?.end ?? 0)
        return min(max(0, time), limit)
    }

    private func startGapTimer(for segment: TimelineSegment, startingAt time: TimeInterval) {
        stopGapTimer()
        gapTimelineStart = time
        gapTimerStartHostTime = CACurrentMediaTime()
        gapTelemetryMarked = false
        isGapActive = true
        audioMixer.setMuted(true)
        audioMixer.stopAll()
        activeClipFrameTask?.cancel()
        activeClipFrameTask = nil

        if let gapIndex = currentSegmentIndex {
            prepareNextClipIfNeeded(after: gapIndex)
        }

        guard !isTimelineTickerActive else {
            gapTimer?.invalidate()
            gapTimer = nil
            return
        }

        // Use composition framerate or min 60fps for smooth time updates when the global ticker is idle
        let updateRate = max(compositionFrameRate, 60.0)
        let timer = Timer(timeInterval: 1.0 / updateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let startTimeline = self.gapTimelineStart,
                      let startHost = self.gapTimerStartHostTime else { return }

                if let gapIndex = self.currentSegmentIndex {
                    self.prepareNextClipIfNeeded(after: gapIndex)
                }

                // Use PlaybackClock for accurate gap timing
                let currentTime = self.playbackClock.currentTime()
                let clamped = min(currentTime, segment.end)
                self.latchedTime = clamped
                self.playbackClock.align(to: clamped)

                Task { [weak self] in
                    await self?.scheduleFrameUpdate(at: clamped, source: "gapTimer")
                }

                if clamped >= segment.end - 1e-6 {
                    if !self.gapTelemetryMarked {
                        TimelineTelemetry.shared.markGapPlaybackOK()
                        self.gapTelemetryMarked = true
                    }
                    self.advanceToNextSegment()
                }
            }
        }
        gapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopGapTimer(disableOverlay: Bool = true) {
        gapTimer?.invalidate()
        gapTimer = nil
        gapTimerStartHostTime = nil
        gapTimelineStart = nil
        if disableOverlay {
            isGapActive = false
            updateAudioForCurrentTime(playing: playbackState == .playing && latchedPlaybackRate != 0, force: true)
        }
        playbackClock.align(to: latchedTime)
    }

    private func updateAudioForCurrentTime(playing: Bool, force: Bool = false) {
        audioMixer.setMuted(desiredAudioMute || !playing)
        let newIndex = compositeSliceIndex(for: latchedTime)
        guard force || newIndex != currentCompositeSliceIndex else { return }
        currentCompositeSliceIndex = newIndex
        let segments = activeAudioSegments(at: latchedTime)
        let clockSnapshot = playbackClock.currentState()
        audioMixer.updateClockState(clockSnapshot)
        audioMixer.activate(segments: segments,
                            timelineTime: latchedTime,
                            rate: latchedPlaybackRate,
                            isPlaying: playing && !isGapActive)
    }

    private func compositeSliceIndex(for time: TimeInterval) -> Int? {
        let epsilon = 1e-6
        for (index, slice) in playbackGraph.compositeSlices.enumerated() {
            if time >= slice.start - epsilon && time < slice.end - epsilon {
                return index
            }
        }
        if let last = playbackGraph.compositeSlices.last,
           time >= last.end - epsilon {
            return playbackGraph.compositeSlices.indices.last
        }
        return nil
    }

    private func activeAudioSegments(at time: TimeInterval) -> [TimelineSegment] {
        guard let index = compositeSliceIndex(for: time),
              index < playbackGraph.compositeSlices.count else { return [] }
        return playbackGraph.compositeSlices[index].orderedSegments
    }

    func compositeSlice(at time: TimeInterval) -> TimelineCompositeSlice? {
        guard let index = compositeSliceIndex(for: time),
              index < playbackGraph.compositeSlices.count else { return nil }
        return playbackGraph.compositeSlices[index]
    }

    func matteAttachment(for clipID: UUID, at time: TimeInterval) -> TimelineMatteAttachment? {
        compositeSlice(at: time)?.mattes[clipID]
    }
    
    /// Returns dictionary of visible clip IDs to their VideoSource instances at current time
    private func getVisibleClips() -> [UUID: VideoSource] {
        let segments = compositeSegments(at: latchedTime)
        var visibleClips: [UUID: VideoSource] = [:]
        
        for segment in segments {
            if let clip = segment.clip, let source = videoSources[clip.id] {
                visibleClips[clip.id] = source
            }
        }
        
        // Also include mattes from composite slice
        if let slice = compositeSlice(at: latchedTime) {
            for (clipID, attachment) in slice.mattes {
                if let source = videoSources[clipID] {
                    visibleClips[clipID] = source
                }
            }
        }
        
        return visibleClips
    }

    private func rebuildVideoSources(for composition: Composition) {
        let compositionSnapshot = composition
        let clipIDs = Set(composition.clips.map(\.id))
        for (clipID, source) in videoSources where !clipIDs.contains(clipID) {
            Task { await source.invalidate() }
            videoSources[clipID] = nil
            frameBuffer[clipID] = nil
            frameBufferTimestamps[clipID] = nil
            frameHistory[clipID] = nil
            framePipeline.stopPipeline(for: clipID)
            clipNaturalSizes.removeValue(forKey: clipID)
        }

        for clip in composition.clips where videoSources[clip.id] == nil {
            guard let url = resolvedURL(for: clip) else {
                print("[Transport] No URL for clip \(clip.id), assetRef: \(clip.assetRef)")
                continue
            }
            print("[Transport] Creating VideoSource for clip \(clip.id) with URL: \(url)")
            print("[Transport] Clip srcRange: start=\(clip.srcRange.start.seconds), duration=\(clip.srcRange.duration.seconds)")

            // DEBUG: Check clip.speed value
            print("🔍 [DEBUG] Clip.speed = \(clip.speed) (expecting 1.0)")

            // After Effects behavior: Videos ALWAYS play at native speed (1.0x)
            // Timeline framerate only affects UI updates, NOT video playback speed
            let baseSpeed = Double(max(clip.speed, 0.0001))

            // FIXED: No speed compensation - videos play at native speed always
            let finalSpeed = baseSpeed  // Videos keep native speed regardless of timeline FPS

            print("[Transport] Video plays at native speed: \(finalSpeed)x (no framerate compensation)")

            let source = VideoSource(clipID: clip.id,
                                     assetURL: url,
                                     sourceStart: clip.srcRange.start.seconds,
                                     sourceDuration: clip.srcRange.duration.seconds,
                                     speed: finalSpeed,
                                     timelineStart: clip.dstStart)
            videoSources[clip.id] = source
            Task {
                do {
                    try await source.prepare()
                    print("[Transport] VideoSource prepared for clip \(clip.id)")

                    if let size = await source.naturalSize() {
                        await MainActor.run { [weak self] in
                            self?.clipNaturalSizes[clip.id] = size
                            self?.updateDirtyRegions(for: compositionSnapshot)
                        }
                    }

                    // Pre-warm: Create first AVAssetReader asynchronously to avoid initial stutter
                    _ = try? await source.copyFrame(at: clip.dstStart, caller: "prewarm-import")
                    print("[Transport] VideoSource pre-warmed (first reader created) for clip \(clip.id)")

                    // Start frame pipeline for this clip
                    await MainActor.run {
                        let videoFrameDuration: TimeInterval
                        if let layerFrameRateString = clip.metadata.userMetadata["videoLayerFrameRate"],
                           let layerFrameRate = Double(layerFrameRateString), layerFrameRate > 0 {
                            videoFrameDuration = 1.0 / layerFrameRate
                        } else if let nativeFrameRateString = clip.metadata.userMetadata["videoNativeFrameRate"],
                                  let nativeFrameRate = Double(nativeFrameRateString), nativeFrameRate > 0 {
                            videoFrameDuration = 1.0 / nativeFrameRate
                        } else {
                            videoFrameDuration = 1.0 / 24.0
                            print("[Transport] WARNING: No video metadata found, using 24fps fallback for clip \(clip.id)")
                        }

                        self.framePipeline.startPipeline(for: clip.id,
                                                          source: source,
                                                          timelineRange: clip.dstStart...clip.dstEnd,
                                                          frameDuration: videoFrameDuration)
                    }

                    // Immediately buffer first frame for scrubbing
                    await self.scheduleFrameUpdate(at: self.latchedTime, source: "videoSourcePrep")
                } catch {
                    print("[Transport] Failed to prepare VideoSource: \(error)")
                }
            }
        }
    }

    private func resolvedURL(for clip: Clip) -> URL? {
        // First check if it's already a valid file URL
        if let url = URL(string: clip.assetRef) {
            if url.isFileURL {
                return url
            }
            // For HTTP URLs, try to get cached version synchronously
            if url.scheme == "http" || url.scheme == "https" {
                // Check if already cached
                let cachedURL = AssetCacheManager.cachedFileURL(for: url)
                if FileManager.default.fileExists(atPath: cachedURL.path) {
                    print("[Transport] Using cached URL for \(url) -> \(cachedURL)")
                    return cachedURL
                }
                print("[Transport] HTTP URL not yet cached: \(url)")
                // Start async download
                Task {
                    do {
                        let cached = try await AssetCacheManager.shared.resolve(originalURL: url)
                        print("[Transport] Downloaded and cached: \(url) -> \(cached)")
                    } catch {
                        print("[Transport] Failed to cache URL: \(error)")
                    }
                }
                return nil // Will be picked up on next rebuild
            }
        }

        // Fallback: try as file path
        let fileURL = URL(fileURLWithPath: clip.assetRef)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }


    private func startTimelineTicker(from time: TimeInterval, rate: Double) {
        print("🕰️ [DEBUG] startTimelineTicker called with rate=\(rate), abs(rate)=\(abs(rate)), .ulpOfOne=\(Double.ulpOfOne)")
        if abs(rate) <= .ulpOfOne {
            timelineTicker.seek(to: time)
            isTimelineTickerActive = false
            latchedTime = time
            playbackClock.pause(at: time)
            return
        }

        // TimelineTicker.start() will call PlaybackClock.play() - no need to call twice
        isTimelineTickerActive = true
        timelineTicker.start(from: time, rate: rate) { [weak self] newTime in
            guard let self else { return }
            self.handleTimelineTick(timelineTime: newTime)
        }
    }

    private func stopTimelineTicker() {
        tickerWarmupTask?.cancel()
        tickerWarmupTask = nil
        activeClipFrameTask?.cancel()
        activeClipFrameTask = nil
        timelineTicker.stop()
        isTimelineTickerActive = false
        playbackClock.pause(at: latchedTime)
    }

    private func handleTimelineTick(timelineTime: TimeInterval) {
        // DEBUG: Log incoming time
        if timelineTime < 0.5 {
            print("📍 [handleTimelineTick] Received time: \(String(format: "%.4f", timelineTime))s")
        }

        guard playbackState == .playing, monotonicGuardEnabled else { return }
        let clamped = clampTimelineTime(timelineTime)
        let hostNow = CACurrentMediaTime()

        guard let (index, segment) = segment(at: clamped) else {
            latchedTime = clamped
            playbackClock.align(to: clamped, hostTime: hostNow)
            return
        }

        if currentSegmentIndex != index {
            currentSegmentIndex = index
            currentCompositeSliceIndex = compositeSliceIndex(for: segment.start)
        }

        if let clip = segment.clip {
            advancePlayback(within: segment,
                            clip: clip,
                            timelineTime: clamped)
        } else {
            isGapActive = true
            let newTime = monotonicGuardEnabled ? max(latchedTime, clamped) : clamped
            latchedTime = newTime

            if let gapIndex = currentSegmentIndex {
                prepareNextClipIfNeeded(after: gapIndex)
            }

            if newTime >= segment.end - 1e-6 {
                if !gapTelemetryMarked {
                    TimelineTelemetry.shared.markGapPlaybackOK()
                    gapTelemetryMarked = true
                }
                advanceToNextSegment()
            }
        }

        let isPlaying = playbackState == .playing && latchedPlaybackRate != 0
        updateAudioForCurrentTime(playing: isPlaying)
        playbackClock.align(to: latchedTime, hostTime: hostNow)
    }

    private func applyDirectTime(_ time: TimeInterval) {
        let clamped = clampTimelineTime(time)
        currentCompositeSliceIndex = compositeSliceIndex(for: clamped)

        if let (index, segment) = segment(at: clamped) {
            currentSegmentIndex = index
            if let clip = segment.clip {
                advancePlayback(within: segment,
                                clip: clip,
                                timelineTime: clamped)
            } else {
                isGapActive = true
                latchedTime = max(segment.start, min(clamped, segment.end))
                activeClipFrameTask?.cancel()
                activeClipFrameTask = nil
            }
        } else {
            currentSegmentIndex = nil
            isGapActive = false
            latchedTime = clamped
        }

        // CRITICAL FIX: Don't prune during active scrubbing!
        // Pruning every 16.7ms is too aggressive and causes flickering
        // Frames are already managed by version checks
        if !isScrubbing {
            pruneFrameCache(keepingUpTo: latchedTime)
        }
        
        playbackClock.align(to: latchedTime)
    }

    private func advancePlayback(within segment: TimelineSegment,
                                 clip: Clip,
                                 timelineTime: TimeInterval) {
        let epsilon = 1e-6
        let clamped = clampTimelineTime(timelineTime)
        isGapActive = false
        let newTime: TimeInterval
        if isTransitioningSegments {
            newTime = clamped
        } else if monotonicGuardEnabled {
            newTime = max(latchedTime, clamped)
        } else {
            newTime = clamped
        }

        // DEBUG
        if newTime < 0.5 && abs(newTime - timelineTime) > 0.001 {
            print("⚠️  [advancePlayback] TIME CHANGED: input=\(String(format: "%.4f", timelineTime))s → output=\(String(format: "%.4f", newTime))s (latchedTime=\(String(format: "%.4f", latchedTime))s)")
        }

        latchedTime = newTime

        if latchedTime >= segment.end - 0.2 && latchedTime != lastPreloadCheckTime {
            lastPreloadCheckTime = latchedTime
            preloadNextSegment()
        }

        if latchedTime >= segment.end - epsilon {
            advanceToNextSegment()
            return
        }

        scheduleActiveClipFrame(for: clip, at: newTime)
    }

    private func scheduleActiveClipFrame(for clip: Clip, at time: TimeInterval) {
        // CRITICAL FIX (Bug #10): ONLY load frames during PLAYBACK!
        // During paused/scrubbing, other mechanisms handle frame loading:
        // - requestTime() calls scheduleFrameUpdate(source: "requestTime-sync")
        // - scrubSeek() calls scheduleFrameUpdate(source: "scrubSeek")
        // If scheduleActiveClipFrame runs during slider/keyboard navigation, it creates a race:
        // - User moves slider quickly: 3210s → 3214s → 3217s → 3220s
        // - scheduleActiveClipFrame(3210s) starts loading
        // - User is already at 3220s
        // - Frame for 3210s finishes loading → cache has WRONG frame!
        // Solution: Only run during .playing, let requestTime/scrubSeek handle paused/scrubbing
        if playbackState != .playing {
            playbackDebugLog("⏭️  [scheduleActiveClipFrame] SKIP - playbackState=\(playbackState), not .playing")
            return
        }

        let videoFrameDuration = videoFrameDuration(for: clip.id)
        let playbackLeadAllowance = leadAllowance(for: clip.id,
                                                 framesAhead: 6.0,
                                                 minimum: 0.18,
                                                 maximum: 0.5)
        let pipelineTolerance = max(videoFrameDuration * 3.0, playbackLeadAllowance)
        let epsilon = max(videoFrameDuration * 0.001, 1e-6)

        if let pipelineFrame = framePipeline.frameMetadata(for: clip.id, at: time) {
            let lead = pipelineFrame.presentationTime - time
            let isWithinLead = lead <= playbackLeadAllowance + epsilon
            let isCloseEnough = abs(pipelineFrame.presentationTime - time) <= pipelineTolerance
            if isWithinLead && isCloseEnough {
                let needsPrimaryUpdate: Bool
                if let cachedTimestamp = frameBufferTimestamps[clip.id] {
                    needsPrimaryUpdate = abs(cachedTimestamp - pipelineFrame.presentationTime) > epsilon
                } else {
                    needsPrimaryUpdate = true
                }

                if needsPrimaryUpdate {
                    cacheFrame(pipelineFrame.pixelBuffer,
                               clipID: clip.id,
                               presentationTime: pipelineFrame.presentationTime,
                               origin: .playback)
                }
                return
            } else if lead > playbackLeadAllowance + epsilon {
                playbackDebugLog("🚫 [scheduleActiveClipFrame] SKIP pipeline frame - too far ahead (lead=\(String(format: "%.3f", lead))s)")
            }
        }

        // CRITICAL FIX: Check if cached frame is still valid (close enough to requested time)
        // Use abs() to handle both past and future frames
        if let existingTimestamp = frameBufferTimestamps[clip.id],
           abs(existingTimestamp - time) <= playbackLeadAllowance {
            return  // Cached frame is close enough, no need to request new one
        }

        guard let source = videoSources[clip.id] else {
            print("🔴 [scheduleActiveClipFrame] NO SOURCE for clip \(clip.id)")
            return
        }

        let minDelta = max(videoFrameDuration * 0.5, 1.0 / 240.0)
        // CRITICAL FIX: Use absolute value for delta check!
        // This prevents skipping frames when scrubbing backwards or after seek
        let delta = abs(time - lastActiveClipFrameRequest)
        if delta < minDelta {
            playbackDebugLog("⏭️  [scheduleActiveClipFrame] SKIP - too soon (delta: \(delta)s)")
            return
        }
        lastActiveClipFrameRequest = time

        if let task = activeClipFrameTask {
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - (activeClipFrameTaskStartTime ?? now)
            let cachedTimestamp = frameBufferTimestamps[clip.id]
            let isTaskStale = cachedTimestamp.map { abs($0 - time) > playbackLeadAllowance * 0.75 } ?? false
            if elapsed > 0.25 || isTaskStale {
                playbackDebugLog("⏹️ [scheduleActiveClipFrame] Cancelling stale task (elapsed=\(String(format: "%.3f", elapsed))s, stale=\(isTaskStale))")
                task.cancel()
                activeClipFrameTask = nil
                activeClipFrameTaskStartTime = nil
            } else {
                playbackDebugLog("⏳ [scheduleActiveClipFrame] SKIP - previous task still running (elapsed=\(String(format: "%.3f", elapsed))s)")
                return
            }
        }

        playbackDebugLog("🎬 [scheduleActiveClipFrame] REQUESTING frame at time=\(String(format: "%.3f", time))s for clip \(clip.name)")

        activeClipFrameTaskStartTime = CFAbsoluteTimeGetCurrent()

        activeClipFrameTask = Task { [weak self] in
            guard let self else { return }

            // CRITICAL FIX (Bug #12): Check if task was cancelled before caching frame!
            // Scenario: Playing at 3.9s, task loading frame at 3.5s
            //           User pauses and scrubs to 3.4s → task gets cancelled
            //           But copyFrame() already finished!
            //           Without this check, frame 3.5s would overwrite cache → WRONG!
            guard !Task.isCancelled else {
                playbackDebugLog("🚫 [scheduleActiveClipFrame] Task CANCELLED before copyFrame")
                await MainActor.run { [weak self] in
                    self?.activeClipFrameTask = nil
                    self?.activeClipFrameTaskStartTime = nil
                }
                return
            }

            if let frame = try? await source.copyFrame(at: time, caller: "scheduleActiveClipFrame") {
                // Check again after async operation!
                guard !Task.isCancelled else {
                    playbackDebugLog("🚫 [scheduleActiveClipFrame] Task CANCELLED after copyFrame - NOT caching frame at \(String(format: "%.3f", time))s")
                    await MainActor.run { [weak self] in
                        self?.activeClipFrameTask = nil
                        self?.activeClipFrameTaskStartTime = nil
                    }
                    return
                }

                playbackDebugLog("✅ [scheduleActiveClipFrame] GOT FRAME at \(String(format: "%.3f", frame.timelineTime))s")
                await MainActor.run { [weak self] in
                    self?.cacheFrame(frame.pixelBuffer,
                                     clipID: clip.id,
                                     presentationTime: frame.timelineTime,
                                     origin: .playback)
                    self?.activeClipFrameTask = nil  // Mark as complete
                    self?.activeClipFrameTaskStartTime = nil
                }
            } else if let latest = await source.latestFrame() {
                guard !Task.isCancelled else {
                    playbackDebugLog("🚫 [scheduleActiveClipFrame] Task CANCELLED - NOT using latest frame")
                    await MainActor.run { [weak self] in
                        self?.activeClipFrameTask = nil
                        self?.activeClipFrameTaskStartTime = nil
                    }
                    return
                }

                print("⚠️  [scheduleActiveClipFrame] Using LATEST frame (decode failed)")
                await MainActor.run { [weak self] in
                    self?.cacheFrame(latest.pixelBuffer,
                                     clipID: clip.id,
                                     presentationTime: latest.timelineTime,
                                     origin: .playback)
                    self?.activeClipFrameTask = nil  // Mark as complete
                    self?.activeClipFrameTaskStartTime = nil
                }
            } else {
                print("❌ [scheduleActiveClipFrame] NO FRAME available")
                await MainActor.run { [weak self] in
                    self?.activeClipFrameTask = nil  // Mark as complete even on failure
                    self?.activeClipFrameTaskStartTime = nil
                }
            }
        }
    }

    private func prepareNextClipIfNeeded(after gapIndex: Int) {
        guard let clipIndex = nextClipIndex(after: gapIndex) else { return }
        if preparedClipSegmentIndex == clipIndex || preparingClipSegmentIndex == clipIndex {
            return
        }

        let segment = playbackGraph.segments[clipIndex]
        guard let _ = segment.clip else { return }

        preparingClipSegmentIndex = clipIndex
        let warmupTime = max(segment.start, latchedTime)

        Task { [weak self] in
            guard let self else { return }
            await self.scheduleFrameUpdate(at: warmupTime, source: "videoSourcePrep")
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.preparingClipSegmentIndex == clipIndex {
                    self.preparedClipSegmentIndex = clipIndex
                    self.preparingClipSegmentIndex = nil
                }
            }
        }
    }

    private func nextClipIndex(after index: Int) -> Int? {
        guard index + 1 < playbackGraph.segments.count else { return nil }
        for candidate in (index + 1)..<playbackGraph.segments.count {
            if playbackGraph.segments[candidate].clip != nil {
                return candidate
            }
        }
        return nil
    }

}
