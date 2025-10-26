import Foundation
import AVFoundation
import Combine

@MainActor
public final class TimelineController: ObservableObject {
    @Published public private(set) var composition: Composition
    @Published public private(set) var stateMachine: TimelineStateMachine
    @Published public var playheadTime: TimeInterval = 0
    @Published public var selection: Set<UUID> = []
    @Published public private(set) var transportState: TransportPlaybackState = .paused

    private let transport = TransportController.shared
    private var cancellables: Set<AnyCancellable> = []
    private var frameDuration: TimeInterval
    private let snapEngine = SnapEngine()
    private let commandStack = AEEditCommandStack()
    @Published public private(set) var segmentsByLayer: [UUID: [TimelineSegment]] = [:]
    @Published public private(set) var playbackTimeline: [TimelineSegment] = []
    @Published public private(set) var compositeTimeline: [TimelineCompositeSlice] = []
    private var selectedLayerIDs: Set<UUID> = []
    private let telemetry = TimelineTelemetry.shared

    public init(initial composition: Composition) {
        // Repair any corrupted clips on initialization
        let repaired = Self.repairCorruptedClips(composition)
        let quantized = repaired.quantizedForTimeline(requestedDuration: repaired.duration)
        self.composition = quantized
        self.stateMachine = TimelineStateMachine(mode: .idle)
        self.frameDuration = quantized.frameTimebase.frameDuration.seconds
        observeTransport()
        transportState = transport.playbackState
        snapEngine.updateFrameRate(quantized.frameRate)
        snapEngine.updateComposition(quantized)
        snapEngine.updatePlayhead(playheadTime)
        rebuildPlaybackSegments(applyToTransport: true)
        snapEngine.updatePlayhead(playheadTime)
    }

    // Expose repair function publicly
    public func repairCurrentComposition() {
        updateComposition(composition)
    }

    // MARK: - Transport integration

    public func requestTime(_ time: TimeInterval, completion: ((Bool) -> Void)?) {
        let clamped = clampTime(time)
        print("📍 [TimelineController] requestTime() CALLED with time=\(String(format: "%.3f", time))s → clamped=\(String(format: "%.3f", clamped))s")
        playheadTime = clamped
        snapEngine.updatePlayhead(clamped)
        transport.requestTime(playheadTime, completion: completion)
        print("📍 [TimelineController] requestTime() completed")
    }

    public func requestPlay(rate: Double, completion: ((Bool) -> Void)?) {
        stateMachine.transition(to: .playback)
        transport.requestPlay(rate: rate, completion: completion)
    }

    public func requestPause() {
        transport.requestPause()
        stateMachine.transition(to: .idle)
    }

    // MARK: - Navigation helpers

    public func stepForward() {
        stepFrames(1)
    }

    public func stepBackward() {
        stepFrames(-1)
    }

    public func stepFrames(_ count: Int) {
        let newTime = playheadTime + Double(count) * frameDuration
        requestTime(newTime, completion: nil)
    }

    public func seekToFrame(_ frameIndex: Int) {
        let newTime = Double(frameIndex) * frameDuration
        requestTime(newTime, completion: nil)
    }

    public func updateComposition(_ newComposition: Composition) {
        // Repair any corrupted clip durations before processing
        let repairedComposition = Self.repairCorruptedClips(newComposition)
        let adjustedComposition = repairedComposition.quantizedForTimeline(requestedDuration: repairedComposition.duration)

        composition = adjustedComposition
        frameDuration = adjustedComposition.frameTimebase.frameDuration.seconds
        snapEngine.updateFrameRate(adjustedComposition.frameRate)
        snapEngine.updateComposition(adjustedComposition)

        // Update transport with frame-exact timebase for NLE-accurate timing
        transport.updateCompositionFrameRate(adjustedComposition.frameRate)

        playheadTime = clampTime(playheadTime)
        rebuildPlaybackSegments(applyToTransport: true)
        snapEngine.updatePlayhead(playheadTime)
    }

    /// Set composition directly (used for framerate updates without full rebuild)
    public func setComposition(_ newComposition: Composition) {
        updateComposition(newComposition)
    }

    private static func repairCorruptedClips(_ comp: Composition) -> Composition {
        let timebase = comp.frameTimebase
        let sanitized = comp.clips.map { clip in
            ClipSanitizer.sanitize(clip, frameTimebase: timebase)
        }
        return comp
            .updating(clips: sanitized)
            .sanitizeMatteSources()
    }

    func perform(operation: AEEditOperation) {
        do {
            // Only pause if we're playing - avoid unnecessary pausing during edits
            if transportState == .playing {
                transport.requestPause()
            }
            let context = AEEditContext(composition: composition,
                                        viewport: TimelineViewport(frameRate: composition.frameRate),
                                        selection: selection)
            let updated = try commandStack.apply(op: operation, context: context, snapEngine: snapEngine)
            updateComposition(updated)
        } catch {
            print("Edit operation failed: \(error)")
        }
    }

    func lift(range: TimelineEditRange? = nil) {
        guard let resolvedRange = resolveRange(range) else { return }
        perform(operation: AELiftOperation(range: resolvedRange, affectedLayerIDs: activeLayerSelection()))
    }

    func extract(range: TimelineEditRange? = nil) {
        guard let resolvedRange = resolveRange(range) else { return }
        perform(operation: AEExtractOperation(range: resolvedRange, affectedLayerIDs: activeLayerSelection()))
    }

    func removeGap(range: TimelineEditRange) {
        perform(operation: AEGapRemoveOperation(range: range))
    }

    func updateLayerSelection(_ ids: Set<UUID>) {
        selectedLayerIDs = ids
    }

    func currentLayerSelection() -> [UUID] {
        Array(selectedLayerIDs)
    }

    func setWorkArea(_ range: TimelineEditRange?) {
        var comp = composition
        if let range {
            let clampedStart = max(0, min(range.start, comp.duration))
            let clampedEnd = min(comp.duration, max(range.end, clampedStart))
            let duration = clampedEnd - clampedStart
            if duration > 1e-6 {
                let timebase = comp.frameTimebase
                let quantizedStart = timebase.quantize(clampedStart, rounding: .floor)
                let quantizedEnd = timebase.quantize(clampedEnd, rounding: .ceil)
                let quantizedDuration = max(quantizedEnd - quantizedStart, 0)
                if quantizedDuration > 1e-6 {
                    comp.workArea = CMTimeRange(start: CMTime(seconds: quantizedStart, preferredTimescale: 600),
                                                duration: CMTime(seconds: quantizedDuration, preferredTimescale: 600))
                } else {
                    comp.workArea = nil
                }
            } else {
                comp.workArea = nil
            }
        } else {
            comp.workArea = nil
        }
        composition = comp
        snapEngine.updateComposition(comp)
        rebuildPlaybackSegments()
    }

    func setWorkIn(at time: TimeInterval) {
        let clamped = clampTime(time)
        let timebase = composition.frameTimebase
        let start = timebase.quantize(clamped, rounding: .floor)
        let minDuration = timebase.frameDuration.seconds
        let currentEnd = composition.workArea?.end.seconds ?? start
        var end = max(start, currentEnd)
        if abs(end - start) < minDuration {
            end = min(composition.duration, start + minDuration)
        }
        setWorkArea(TimelineEditRange(start: start, end: end))
    }

    func setWorkOut(at time: TimeInterval) {
        let clamped = clampTime(time)
        let timebase = composition.frameTimebase
        let end = timebase.quantize(clamped, rounding: .ceil)
        let minDuration = timebase.frameDuration.seconds
        let currentStart = composition.workArea?.start.seconds ?? 0
        var start = min(currentStart, end)
        if abs(end - start) < minDuration {
            start = max(0, end - minDuration)
        }
        setWorkArea(TimelineEditRange(start: start, end: end))
    }

    func clearWorkArea() {
        setWorkArea(nil)
    }

    func undo() {
        if let restored = commandStack.undo(current: composition) {
            updateComposition(restored)
        }
    }

    func redo() {
        if let replayed = commandStack.redo(current: composition) {
            updateComposition(replayed)
        }
    }

    func splitClip(at time: TimeInterval) {
        perform(operation: AESplitClipOperation(time: clampTime(time)))
    }

    func deleteClip(at time: TimeInterval) {
        perform(operation: AEDeleteClipOperation(time: clampTime(time)))
    }

    func reorderLayers(moving layerIDs: [UUID], to destinationIndex: Int) {
        guard !layerIDs.isEmpty else { return }
        perform(operation: AEReorderLayersOperation(movingLayerIDs: layerIDs,
                                                    destinationIndex: destinationIndex))
    }

    func updateLayerSwitches(layerID: UUID,
                             muted: Bool? = nil,
                             solo: Bool? = nil,
                             locked: Bool? = nil,
                             blendMode: BlendMode? = nil,
                             matteMode: TrackMatteMode? = nil,
                             matteSourceLayerID: UUID?? = nil) {
        guard muted != nil || solo != nil || locked != nil || blendMode != nil || matteMode != nil || matteSourceLayerID != nil else { return }
        perform(operation: AELayerSwitchOperation(layerID: layerID,
                                                  muted: muted,
                                                  solo: solo,
                                                  locked: locked,
                                                  blendMode: blendMode,
                                                  matteMode: matteMode,
                                                  matteSourceLayerID: matteSourceLayerID))
    }

    func moveClip(id clipID: UUID, delta: TimeInterval) {
        guard abs(delta) > 1e-6 else {
            print("moveClip: delta too small (\(delta))")
            return
        }
        print("moveClip: clipID=\(clipID), delta=\(delta)")
        perform(operation: AEMoveOperation(clipIDs: [clipID], delta: delta))
    }

    func slipClip(id clipID: UUID, delta: TimeInterval) {
        guard abs(delta) > 1e-6 else {
            print("slipClip: delta too small (\(delta))")
            return
        }
        print("slipClip: clipID=\(clipID), delta=\(delta)")
        perform(operation: AESlipOperation(clipID: clipID, delta: delta))
    }

    func slideClip(id clipID: UUID, delta: TimeInterval) {
        guard abs(delta) > 1e-6 else { return }
        perform(operation: AESlideOperation(clipID: clipID, delta: delta))
    }

    func trimInClip(id clipID: UUID, delta: TimeInterval) {
        guard abs(delta) > 1e-6 else { return }
        let targetTime = composition.clips.first { $0.id == clipID }?.dstStart ?? 0
        perform(operation: AETrimInOperation(clipID: clipID, targetTime: targetTime + delta, rippleMode: false))
    }

    func trimOutClip(id clipID: UUID, delta: TimeInterval) {
        guard abs(delta) > 1e-6 else { return }
        let targetTime = composition.clips.first { $0.id == clipID }?.dstEnd ?? 0
        perform(operation: AETrimOutOperation(clipID: clipID, targetTime: targetTime + delta, rippleMode: false))
    }

    func beginScrub() {
        stateMachine.transition(to: .scrub)
        transport.beginScrub()
    }

    func scrub(to time: TimeInterval) {
        let clamped = clampTime(time)
        playheadTime = clamped
        snapEngine.updatePlayhead(clamped)
        transport.scrubSeek(to: clamped)
    }

    func endScrub(resumeIfWanted: Bool) {
        transport.endScrub(resumeIfWanted: resumeIfWanted)
        let nextMode: TimelineMode = transport.latchedPlaybackRate != 0 ? .playback : .idle
        stateMachine.transition(to: nextMode)
    }

    func updateClip(id clipID: UUID, mutate: (inout Clip) -> Void) {
        var updatedComposition = composition
        guard let index = updatedComposition.clips.firstIndex(where: { $0.id == clipID }) else { return }
        var clip = updatedComposition.clips[index]
        let originalClip = clip
        mutate(&clip)
        guard clip != originalClip else { return }
        updatedComposition.clips[index] = clip
        updateComposition(updatedComposition)
    }

    // MARK: - Private

    private func observeTransport() {
        transport.$latchedTime
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                guard let self else { return }
                let clamped = clampTime(time)
                self.playheadTime = clamped
                self.snapEngine.updatePlayhead(clamped)
            }
            .store(in: &cancellables)

        transport.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.transportState = state
            }
            .store(in: &cancellables)
    }

    private func clampTime(_ time: TimeInterval) -> TimeInterval {
        min(max(0, time), composition.duration)
    }

    private func rebuildPlaybackSegments(applyToTransport: Bool = false) {
        let playbackData: TimelinePlaybackData

        if applyToTransport {
            playbackData = transport.applyComposition(composition)
            let syncedTime = clampTime(transport.latchedTime)
            playheadTime = syncedTime
            transport.requestTime(syncedTime, completion: nil)
        } else {
            playbackData = TimelinePlaybackMapper.segments(for: composition)
        }

        segmentsByLayer = playbackData.byLayer
        playbackTimeline = playbackData.timeline
        compositeTimeline = playbackData.compositeTimeline
    }

    func segments(for layerID: UUID, duration: TimeInterval) -> [TimelineSegment] {
        if let segments = segmentsByLayer[layerID] {
            return segments
        }
        return [TimelineSegment(start: 0, end: duration, clip: nil, layerID: layerID)]
    }

    func timelineTime(for assetSeconds: TimeInterval) -> TimeInterval? {
        let sortedClips = composition.clips.sorted { $0.dstStart < $1.dstStart }
        for clip in sortedClips {
            let srcStart = clip.srcRange.start.seconds
            let srcEnd = clip.srcRange.end.seconds
            if assetSeconds >= srcStart && assetSeconds <= srcEnd {
                let srcDelta = assetSeconds - srcStart
                let speed = Double(max(clip.speed, 0.0001))
                let timelineDelta = srcDelta / speed
                return clip.dstStart + timelineDelta
            } else if assetSeconds < srcStart {
                return clip.dstStart
            }
        }

        if let lastClip = sortedClips.last {
            return lastClip.dstEnd
        }

        return nil
    }

    func assetTime(for timelineSeconds: TimeInterval) -> CMTime? {
        let sortedClips = composition.clips.sorted { $0.dstStart < $1.dstStart }
        for clip in sortedClips {
            let dstStart = clip.dstStart
            let dstEnd = clip.dstEnd
            guard timelineSeconds >= dstStart && timelineSeconds <= dstEnd else { continue }

            let localTimeline = timelineSeconds - dstStart
            let speed = Double(max(clip.speed, 0.0001))
            let sourceDelta = localTimeline * speed
            let sourceSeconds = clip.srcRange.start.seconds + sourceDelta
            let timescale = clip.srcRange.duration.timescale != 0 ? clip.srcRange.duration.timescale : 600
            return CMTime(seconds: sourceSeconds, preferredTimescale: timescale)
        }
        return nil
    }

    private func activeLayerSelection() -> Set<UUID>? {
        selectedLayerIDs.isEmpty ? nil : selectedLayerIDs
    }

    private func resolveRange(_ override: TimelineEditRange?) -> TimelineEditRange? {
        if let override {
            return override
        }
        if let workArea = composition.workArea {
            let duration = workArea.duration.seconds
            if duration > 1e-6 {
                return TimelineEditRange(start: workArea.start.seconds, end: workArea.end.seconds)
            }
        }
        return nil
    }
}
