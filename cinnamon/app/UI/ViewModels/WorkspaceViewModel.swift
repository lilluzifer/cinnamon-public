import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var focusedPanel: PanelFocus = .viewer
    @Published var selectedLayerIDs: Set<UUID> = []
    @Published var selectedPropertyIDs: Set<UUID> = []
    @Published var workAreaRange: ClosedRange<Double> = 0...10
    @Published var playheadTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var isScrubbing: Bool = false
    @Published var isAudioMuted: Bool = false {
        didSet {
            transport.desiredAudioMute = isAudioMuted
        }
    }
    @Published var selectedAssetURL: URL?
    @Published var recentAssets: [URL] = []
    @Published var canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published var currentCompositionFrameRate: Double = 24.0

    @Published var layers: [LayerSummary] = []
    @Published var projectItems: [ProjectItem] = ProjectItem.demoProject
    @Published var inspectorState: ClipInspectorState?
    @Published var isGapActive: Bool = false
    @Published var isDiagnosticsActive: Bool = false

    let timelineController: TimelineController
    private let transport = TransportController.shared
    private var cancellables = Set<AnyCancellable>()
    private var restoreAudioAfterScrub = false

    init() {
        // Initialize timeline controller with empty composition
        let initialComposition = Composition(frameRate: ProjectSettings.shared.frameRate.rawValue,
                                             duration: 10,
                                             tracks: [],
                                             clips: [],
                                             markers: [],
                                             workArea: nil)
        timelineController = TimelineController(initial: initialComposition)

        transport.desiredAudioMute = isAudioMuted

        // Listen for project framerate changes
        NotificationCenter.default.addObserver(
            forName: .projectFrameRateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleProjectFrameRateChange()
        }

        transport.$latchedTime
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)  // 30fps UI updates
            .sink { [weak self] time in
                guard let self else { return }
                // Only update if time changed significantly (prevent micro-updates)
                if abs(self.playheadTime - time) > 0.001 {
                    self.playheadTime = time
                    self.rebuildState()
                }
            }
            .store(in: &cancellables)

        transport.$latchedPlaybackRate
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in
                self?.isPlaying = abs(rate) > 0.0001
            }
            .store(in: &cancellables)

        transport.$isScrubbing
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.isScrubbing = active
            }
            .store(in: &cancellables)

        transport.$isGapActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.isGapActive = active
            }
            .store(in: &cancellables)

        timelineController.$composition
            .receive(on: RunLoop.main)
            .sink { [weak self] composition in
                guard let self else { return }
                if let workArea = composition.workArea {
                    self.workAreaRange = workArea.start.seconds...workArea.end.seconds
                } else {
                    self.workAreaRange = 0...composition.duration
                }
                self.rebuildState(with: composition)
            }
            .store(in: &cancellables)

        // Listen for canvas size changes
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(canvasSizeChanged(_:)),
                                              name: Notification.Name("CanvasSizeChanged"),
                                              object: nil)
    }

    @objc private func canvasSizeChanged(_ notification: Notification) {
        if let size = notification.userInfo?["size"] as? CGSize {
            canvasSize = size
        }
    }

    func focus(_ panel: PanelFocus) {
        focusedPanel = panel
    }

    func selectLayer(_ id: UUID, toggle: Bool = false) {
        if toggle {
            if selectedLayerIDs.contains(id) {
                selectedLayerIDs.remove(id)
            } else {
                selectedLayerIDs.insert(id)
            }
        } else {
            selectedLayerIDs = [id]
        }
        timelineController.updateLayerSelection(selectedLayerIDs)
        rebuildState()
    }

    func setSelectedAsset(_ url: URL) {
        selectedAssetURL = url
        appendToRecent(url)

        Task {
            do {
                let localURL = try await AssetCacheManager.shared.resolve(originalURL: url)
                let asset = AVURLAsset(url: localURL)
                let durationTime = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                var naturalSize = CGSize(width: 1920, height: 1080)
                if let track = videoTracks.first {
                    let size = try await track.load(.naturalSize)
                    naturalSize = CGSize(width: abs(size.width), height: abs(size.height))
                }
                var frameRate = 24.0
                for track in videoTracks {
                    if let nominal = try? await track.load(.nominalFrameRate), nominal > 0 {
                        frameRate = Double(nominal)
                        break
                    }
                }

                let durationSeconds = max(durationTime.seconds, 0.1)
                let assetID = AssetDurationRegistry.shared.identifier(for: url)
                AssetDurationRegistry.shared.register(url: localURL, identifier: assetID, duration: durationSeconds)

                var clipMetadata = ClipMetadata()
                clipMetadata.userMetadata["assetDuration"] = String(durationSeconds)
                clipMetadata.userMetadata["assetURL"] = localURL.absoluteString
                clipMetadata.userMetadata["sourceURL"] = url.absoluteString
                clipMetadata.userMetadata["assetID"] = assetID
                clipMetadata.userMetadata["assetDurationOriginal"] = String(durationSeconds)
                clipMetadata.userMetadata["videoNativeFrameRate"] = String(frameRate)

                // Store video layer framerate (always native - After Effects behavior)
                let videoLayerFrameRate = frameRate  // Videos keep native framerate always
                clipMetadata.userMetadata["videoLayerFrameRate"] = String(videoLayerFrameRate)
                clipMetadata.userMetadata["videoWidth"] = String(format: "%.0f", naturalSize.width)
                clipMetadata.userMetadata["videoHeight"] = String(format: "%.0f", naturalSize.height)

                await MainActor.run {
                    // After Effects behavior: Composition uses PROJECT framerate, NOT video framerate!
                    // Video layers keep their native framerate independent of composition
                    let compositionFrameRate = ProjectSettings.shared.frameRate.rawValue

                    print("🎬 [DEBUG] Video native framerate: \(frameRate)fps")
                    print("🎬 [DEBUG] Composition framerate: \(compositionFrameRate)fps (from project settings)")
                    print("🎬 [DEBUG] Video will play at native speed, composition ticks at project framerate")

                    // FIXED: Only update if different to avoid SwiftUI update loops
                    if abs(self.currentCompositionFrameRate - compositionFrameRate) > 0.01 {
                        self.currentCompositionFrameRate = compositionFrameRate
                        NotificationCenter.default.post(name: .compositionFrameRateChanged,
                                                       object: nil,
                                                       userInfo: ["frameRate": compositionFrameRate])
                        print("🔧 [DEBUG] Updated composition framerate: \(self.currentCompositionFrameRate)fps")
                    }

                    self.prepareComposition(with: localURL,
                                             sourceURL: url,
                                             duration: durationTime,
                                             frameRate: compositionFrameRate,
                                             metadata: clipMetadata)
                }
            } catch {
                print("Asset load error: \(error)")
            }
        }
    }

    private func prefetchAssets(for clips: [Clip]) {
        let urls: [URL] = clips.compactMap { clip in
            if let source = clip.metadata.userMetadata["sourceURL"], let url = URL(string: source) {
                return url
            }
            if let url = URL(string: clip.assetRef) {
                return url
            }
            return nil
        }
        guard !urls.isEmpty else { return }
        Task {
            await AssetCacheManager.shared.prefetch(urls: urls)
        }
    }

    private func rebuildState() {
        rebuildState(with: timelineController.composition)
    }

    private func rebuildState(with composition: Composition) {
        let time = playheadTime
        let frameDuration = composition.frameRate > 0 ? 1.0 / composition.frameRate : 1.0 / 24.0
        let epsilon = max(frameDuration * 0.5, 1e-6)

        let tracks = composition.tracks.sorted { $0.stackIndex > $1.stackIndex }
        var trackByID: [UUID: Track] = [:]
        for track in tracks { trackByID[track.id] = track }

        let clipByID = Dictionary(uniqueKeysWithValues: composition.clips.map { ($0.id, $0) })

        var activeClipByLayer: [UUID: Clip] = [:]
        for clip in composition.clips {
            let layerID = clip.transformRef ?? clip.id
            let start = clip.dstStart
            let end = clip.dstEnd
            guard time >= start - epsilon && time < end - epsilon else { continue }
            if let existing = activeClipByLayer[layerID] {
                if clip.dstStart > existing.dstStart {
                    activeClipByLayer[layerID] = clip
                }
            } else {
                activeClipByLayer[layerID] = clip
            }
        }

        var layerAboveMap: [UUID: Track] = [:]
        for (index, track) in tracks.enumerated() where index > 0 {
            layerAboveMap[track.id] = tracks[index - 1]
        }

        var matteTargets: [UUID: [MatteTargetInfo]] = [:]
        for clip in composition.clips where clip.matteMode != .none {
            let layerID = clip.transformRef ?? clip.id
            guard let targetTrack = trackByID[layerID] else { continue }
            guard time >= clip.dstStart - epsilon && time < clip.dstEnd - epsilon else { continue }

            var matteLayerID: UUID?
            if clip.useLayerAbove {
                matteLayerID = layerAboveMap[layerID]?.id
            } else if let matteID = clip.matteSourceID,
                      let matteClip = clipByID[matteID] {
                matteLayerID = matteClip.transformRef ?? matteClip.id
            }

            guard let resolvedMatteLayerID = matteLayerID,
                  let _ = trackByID[resolvedMatteLayerID] else { continue }

            let targetInfo = MatteTargetInfo(id: targetTrack.id, name: targetTrack.name)
            matteTargets[resolvedMatteLayerID, default: []].append(targetInfo)
        }

        var summaries: [LayerSummary] = []
        summaries.reserveCapacity(tracks.count)

        for track in tracks {
            var summary = LayerSummary(track: track)
            if let activeClip = activeClipByLayer[track.id] {
                summary.activeClipID = activeClip.id
                summary.activeClipName = activeClip.name
                summary.matteMode = activeClip.matteMode
                summary.usesLayerAbove = activeClip.useLayerAbove
                summary.hideAsRender = activeClip.hideAsRender
                if activeClip.useLayerAbove {
                    summary.matteSourceLayerID = layerAboveMap[track.id]?.id
                    summary.matteSourceClipID = nil
                } else if let matteID = activeClip.matteSourceID,
                          let matteClip = clipByID[matteID] {
                    summary.matteSourceLayerID = matteClip.transformRef ?? matteClip.id
                    summary.matteSourceClipID = matteClip.id
                } else {
                    summary.matteSourceLayerID = nil
                    summary.matteSourceClipID = nil
                }
            }
            summary.matteTargets = matteTargets[track.id] ?? []
            summaries.append(summary)
        }

        let validLayerIDs = Set(tracks.map { $0.id })
        selectedLayerIDs = selectedLayerIDs.filter { validLayerIDs.contains($0) }
        if selectedLayerIDs.isEmpty, let first = tracks.first {
            selectedLayerIDs = [first.id]
            timelineController.updateLayerSelection(selectedLayerIDs)
        }

        // Only update layers if they actually changed to prevent SwiftUI publishing loops
        if !layersAreEqual(layers, summaries) {
            layers = summaries
        }

        let newInspectorState = buildInspectorState(layers: summaries,
                                                   composition: composition,
                                                   clipByID: clipByID,
                                                   layerAboveMap: layerAboveMap,
                                                   activeClipByLayer: activeClipByLayer,
                                                   time: time)

        // Only update inspectorState if it actually changed to prevent SwiftUI publishing loops
        if !inspectorStatesAreEqual(inspectorState, newInspectorState) {
            inspectorState = newInspectorState
        }
    }

    private func buildInspectorState(layers: [LayerSummary],
                                     composition: Composition,
                                     clipByID: [UUID: Clip],
                                     layerAboveMap: [UUID: Track],
                                     activeClipByLayer: [UUID: Clip],
                                     time: TimeInterval) -> ClipInspectorState? {
        guard let selectedLayerID = selectedLayerIDs.first,
              let layer = layers.first(where: { $0.id == selectedLayerID }),
              let clipID = layer.activeClipID,
              let clip = clipByID[clipID] else {
            return nil
        }

        let availableSources = layers
            .filter { $0.stackIndex > layer.stackIndex }
            .compactMap { summary -> MatteSourceOption? in
                guard let sourceClipID = summary.activeClipID else { return nil }
                return MatteSourceOption(id: sourceClipID, layerID: summary.id, name: summary.name)
            }

        var layerAboveOption: MatteSourceOption?
        if let aboveTrack = layerAboveMap[layer.id],
           let aboveSummary = layers.first(where: { $0.id == aboveTrack.id }),
           let aboveClipID = aboveSummary.activeClipID {
            layerAboveOption = MatteSourceOption(id: aboveClipID, layerID: aboveSummary.id, name: aboveSummary.name)
        }

        let isMatteSource = !(layer.matteTargets.isEmpty)

        return ClipInspectorState(clipID: clip.id,
                                  layerID: layer.id,
                                  layerName: layer.name,
                                  transform: clip.transform,
                                  matteMode: clip.matteMode,
                                  matteSourceClipID: clip.matteSourceID,
                                  useLayerAbove: clip.useLayerAbove,
                                  hideAsRender: clip.hideAsRender,
                                  availableSources: availableSources,
                                  layerAboveOption: layerAboveOption,
                                  isMatteSource: isMatteSource)
    }

    @MainActor
    private func prepareComposition(with localURL: URL,
                                    sourceURL: URL,
                                    duration: CMTime,
                                    frameRate: Double,
                                    metadata: ClipMetadata) {
        let srcRange = CMTimeRange(start: .zero, duration: duration)
        let durationSeconds = max(duration.seconds, 0.1)

        if timelineController.composition.clips.isEmpty {
            let track = Track(stackIndex: 0,
                              kind: .video,
                              name: sourceURL.lastPathComponent,
                              muted: false,
                              solo: false,
                              locked: false,
                              color: .cyan,
                              blendMode: .normal)

            // Create a centered transform based on actual canvas size
            var transform = Transform2D()
            let centerX = Float(canvasSize.width / 2)
            let centerY = Float(canvasSize.height / 2)
            transform.position = SIMD2<Float>(centerX, centerY)

            let clip = Clip(name: sourceURL.lastPathComponent,
                            assetRef: localURL.absoluteString,
                            srcRange: srcRange,
                            dstStart: 0,
                            enabled: true,
                            audioTrackIndex: nil,
                            videoTrackIndex: 0,
                            transform: transform,
                            transformRef: track.id,
                            metadata: metadata)

            let keyframeTrack = TimelineKeyframeTrack(layerID: track.id,
                                                      propertyPath: "transform.opacity",
                                                      keyframes: [
                                                        TimelineKeyframe(time: 0, value: 100),
                                                        TimelineKeyframe(time: clip.duration, value: 100)
                                                      ])

            let composition = Composition(frameRate: frameRate,
                                          duration: clip.duration,
                                          tracks: [track],
                                          clips: [clip],
                                          markers: [],
                                          workArea: srcRange,
                                          keyframeTracks: [keyframeTrack])

            workAreaRange = 0...durationSeconds
            timelineController.updateComposition(composition)
            let layerSelection: Set<UUID> = [track.id]
            timelineController.updateLayerSelection(layerSelection)
            selectedLayerIDs = layerSelection
            transport.requestTime(0, completion: nil)
            play()
            prefetchAssets(for: [clip])
        } else {
            appendClipToExistingTimeline(assetURL: localURL,
                                         displayName: sourceURL.lastPathComponent,
                                         durationTime: duration,
                                         metadata: metadata)
        }
    }

    private func appendClipToExistingTimeline(assetURL: URL,
                                              displayName: String,
                                              durationTime: CMTime,
                                              metadata: ClipMetadata) {
        var composition = timelineController.composition
        let newStackIndex = (composition.tracks.map(\.stackIndex).max() ?? -1) + 1
        let trackID = UUID()

        let track = Track(id: trackID,
                          stackIndex: newStackIndex,
                          kind: .video,
                          name: displayName,
                          muted: false,
                          solo: false,
                          locked: false,
                          color: .cyan,
                          blendMode: .normal)

        let srcRange = CMTimeRange(start: .zero, duration: durationTime)
        let clipStart = max(0, playheadTime)

        // Create a centered transform based on actual canvas size
        var transform = Transform2D()
        let centerX = Float(canvasSize.width / 2)
        let centerY = Float(canvasSize.height / 2)
        transform.position = SIMD2<Float>(centerX, centerY)

        let clip = Clip(name: displayName,
                        assetRef: assetURL.absoluteString,
                        srcRange: srcRange,
                        dstStart: clipStart,
                        enabled: true,
                        audioTrackIndex: nil,
                        videoTrackIndex: newStackIndex,
                        transform: transform,
                        transformRef: trackID,
                        metadata: metadata)

        let keyframeTrack = TimelineKeyframeTrack(layerID: trackID,
                                                  propertyPath: "transform.opacity",
                                                  keyframes: [
                                                    TimelineKeyframe(time: clipStart, value: 100),
                                                    TimelineKeyframe(time: clip.dstEnd, value: 100)
                                                  ])

        composition.tracks.append(track)
        composition.clips.append(clip)
        composition.keyframeTracks.append(keyframeTrack)
        composition.duration = max(composition.duration, clip.dstEnd)
        workAreaRange = 0...max(workAreaRange.upperBound, clip.dstEnd)

        timelineController.updateComposition(composition)
        let selection: Set<UUID> = [trackID]
        timelineController.updateLayerSelection(selection)
        selectedLayerIDs = selection
        prefetchAssets(for: [clip])
    }

    private func appendToRecent(_ url: URL) {
        recentAssets.removeAll { $0 == url }
        recentAssets.insert(url, at: 0)
        if recentAssets.count > 10 {
            recentAssets.removeLast(recentAssets.count - 10)
        }
    }

    func setWorkInAtPlayhead() {
        timelineController.setWorkIn(at: playheadTime)
    }

    func setWorkOutAtPlayhead() {
        timelineController.setWorkOut(at: playheadTime)
    }

    func clearWorkArea() {
        timelineController.clearWorkArea()
    }

    func liftWorkArea() {
        timelineController.lift(range: nil)
    }

    func extractWorkArea() {
        timelineController.extract(range: nil)
    }

    func play(rate: Double = 1.0) {
        // If playhead is at or near the end, jump to start first
        let duration = timelineController.composition.duration
        if playheadTime >= duration - 0.01 {
            // Jump to start (or work area start if set)
            if let workArea = timelineController.composition.workArea {
                timelineController.requestTime(workArea.start.seconds, completion: nil)
            } else {
                timelineController.requestTime(0, completion: nil)
            }
        }

        transport.requestPlay(rate: rate) { [weak self] success in
            if success {
                self?.isPlaying = true
            }
        }
    }

    func pause() {
        transport.requestPause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            // If playhead is at or near the end, jump to start before playing
            let duration = timelineController.composition.duration
            if playheadTime >= duration - 0.01 {
                // Jump to start (or work area start if set)
                if let workArea = timelineController.composition.workArea {
                    timelineController.requestTime(workArea.start.seconds, completion: nil)
                } else {
                    timelineController.requestTime(0, completion: nil)
                }
            }
            play()
        }
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard let layer = layers.first(where: { $0.id == id }) else { return }
        timelineController.updateLayerSwitches(layerID: id, muted: layer.isVisible)
    }

    func toggleLayerSolo(_ id: UUID) {
        guard let layer = layers.first(where: { $0.id == id }) else { return }
        timelineController.updateLayerSwitches(layerID: id, solo: !layer.isSolo)
    }

    func toggleLayerLock(_ id: UUID) {
        guard let layer = layers.first(where: { $0.id == id }) else { return }
        timelineController.updateLayerSwitches(layerID: id, locked: !layer.isLocked)
    }

    func setLayerBlendMode(_ id: UUID, mode: BlendMode) {
        timelineController.updateLayerSwitches(layerID: id, blendMode: mode)
    }

    func updateClipTransform(clipID: UUID?, modify: (inout Transform2D) -> Void) {
        guard let clipID else { return }
        timelineController.updateClip(id: clipID) { clip in
            var updatedTransform = clip.transform
            let originalTransform = updatedTransform
            modify(&updatedTransform)
            if updatedTransform != originalTransform {
                clip.transform = updatedTransform
            }
        }
    }

    func setClipTransform(clipID: UUID?, transform: Transform2D) {
        guard let clipID else { return }
        timelineController.updateClip(id: clipID) { clip in
            clip.transform = transform
        }
    }

    func setClipMatte(clipID: UUID?, mode: TrackMatteMode, selection: MatteSourceSelection) {
        guard let clipID else { return }
        timelineController.updateClip(id: clipID) { clip in
            clip.matteMode = mode
            let resolvedSelection: MatteSourceSelection = mode == .none ? .none : selection
            switch resolvedSelection {
            case .none:
                clip.useLayerAbove = false
                clip.matteSourceID = nil
            case .layerAbove:
                clip.useLayerAbove = true
                clip.matteSourceID = nil
            case .clip(let sourceClipID):
                clip.useLayerAbove = false
                clip.matteSourceID = sourceClipID
            }
        }
    }

    func setClipHideAsRender(clipID: UUID?, hide: Bool) {
        guard let clipID else { return }
        timelineController.updateClip(id: clipID) { clip in
            clip.hideAsRender = hide
        }
    }

    func matteSourceOptions(for layerID: UUID) -> [MatteSourceOption] {
        guard let layer = layers.first(where: { $0.id == layerID }) else { return [] }
        return layers
            .filter { $0.stackIndex > layer.stackIndex }
            .compactMap { summary -> MatteSourceOption? in
                guard let clipID = summary.activeClipID else { return nil }
                return MatteSourceOption(id: clipID, layerID: summary.id, name: summary.name)
            }
    }

    func layerAboveOption(for layerID: UUID) -> MatteSourceOption? {
        guard let index = layers.firstIndex(where: { $0.id == layerID }), index > 0 else { return nil }
        let aboveLayer = layers[index - 1]
        guard let clipID = aboveLayer.activeClipID else { return nil }
        return MatteSourceOption(id: clipID, layerID: aboveLayer.id, name: aboveLayer.name)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        playheadTime = clamped
        transport.requestTime(clamped, completion: nil)
    }

    private func handleProjectFrameRateChange() {
        // When project framerate changes, preserve composition's native framerate
        // Apply After Effects logic: composition keeps video's native framerate regardless of project settings
        guard !timelineController.composition.clips.isEmpty else { return }

        // Get the current composition and update its framerate
        var composition = timelineController.composition

        // Extract framerates from first clip's metadata
        if let firstClip = composition.clips.first,
           let nativeFrameRateString = firstClip.metadata.userMetadata["videoNativeFrameRate"],
           let nativeFrameRate = Double(nativeFrameRateString) {

            // After Effects behavior: Videos keep native framerate
            let videoLayerFrameRate = nativeFrameRate

            // Update video layer framerate in metadata for all clips
            var updatedComposition = composition
            updatedComposition.clips = composition.clips.map { clip in
                var updatedClip = clip
                if let nativeStr = clip.metadata.userMetadata["videoNativeFrameRate"],
                   let nativeRate = Double(nativeStr) {
                    // After Effects: videos keep native framerate
                    updatedClip.metadata.userMetadata["videoLayerFrameRate"] = String(nativeRate)
                }
                return updatedClip
            }

            // Composition framerate = first video (auto mode)
            let compositionFrameRate = nativeFrameRate

            // Update current composition framerate and notify observers
            currentCompositionFrameRate = compositionFrameRate
            NotificationCenter.default.post(name: .compositionFrameRateChanged,
                                           object: nil,
                                           userInfo: ["frameRate": compositionFrameRate])

            // Update composition with new framerate and updated clip metadata
            updatedComposition.frameRate = compositionFrameRate
            timelineController.setComposition(updatedComposition)

            print("Updated composition framerate: \(compositionFrameRate) (native: \(nativeFrameRate))")
        }
    }

    func nudgePlayhead(by delta: Double) {
        seek(to: playheadTime + delta)
    }

    func beginScrub() {
        restoreAudioAfterScrub = !isAudioMuted
        if restoreAudioAfterScrub {
            isAudioMuted = true
        }
        timelineController.beginScrub()
    }

    func scrub(to seconds: Double) {
        timelineController.scrub(to: max(0, seconds))
    }

    func endScrub() {
        timelineController.endScrub(resumeIfWanted: false)
        if restoreAudioAfterScrub {
            isAudioMuted = false
        }
        restoreAudioAfterScrub = false
    }

    func splitClipAtPlayhead() {
        timelineController.splitClip(at: playheadTime)
    }

    func deleteClipAtPlayhead() {
        timelineController.deleteClip(at: playheadTime)
    }

    func undoTimeline() {
        timelineController.undo()
    }

    func reorderLayers(movingLayerIDs: [UUID], targetDisplayIndex: Int) {
        let expanded = expandedMovableIDs(from: movingLayerIDs)
        guard !expanded.isEmpty else { return }

        let ascendingOrder = layers.sorted { $0.stackIndex < $1.stackIndex }.map(\.id)
        let movingSet = Set(expanded)
        let movingAscending = ascendingOrder.filter { movingSet.contains($0) }
        guard !movingAscending.isEmpty else { return }

        let displayOrder = layers.map(\.id)
        let blockDisplay = displayOrder.filter { movingSet.contains($0) }
        var remainingDisplay = displayOrder.filter { !movingSet.contains($0) }
        let clampedIndex = max(0, min(targetDisplayIndex, remainingDisplay.count))
        remainingDisplay.insert(contentsOf: blockDisplay, at: clampedIndex)
        let desiredAscending = Array(remainingDisplay.reversed())

        guard let destination = destinationIndex(originalAscending: ascendingOrder,
                                                movingAscending: movingAscending,
                                                desiredAscending: desiredAscending) else {
            return
        }

        timelineController.reorderLayers(moving: movingAscending, to: destination)
    }

    func bringSelectedLayersForward() {
        guard let block = currentMovableSelectionBlock(), block.displayStart > 0 else { return }
        let newIndex = block.displayStart - 1
        reorderLayers(movingLayerIDs: block.ids, targetDisplayIndex: newIndex)
    }

    func sendSelectedLayersBackward() {
        guard let block = currentMovableSelectionBlock() else { return }
        let limit = max(0, layers.count - block.displayCount)
        guard block.displayStart < limit else { return }
        let newIndex = min(block.displayStart + 1, limit)
        reorderLayers(movingLayerIDs: block.ids, targetDisplayIndex: newIndex)
    }

    func bringSelectedLayersToFront() {
        guard let block = currentMovableSelectionBlock(), block.displayStart > 0 else { return }
        reorderLayers(movingLayerIDs: block.ids, targetDisplayIndex: 0)
    }

    func sendSelectedLayersToBack() {
        guard let block = currentMovableSelectionBlock() else { return }
        let target = layers.count
        guard block.displayStart + block.displayCount < target else { return }
        reorderLayers(movingLayerIDs: block.ids, targetDisplayIndex: target)
    }

    private func expandedMovableIDs(from ids: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let lockedSet = Set(layers.filter { $0.isLocked }.map(\.id))
        var expanded: Set<UUID> = Set(ids.filter { !lockedSet.contains($0) })
        guard !expanded.isEmpty else { return [] }

        var didChange = true
        while didChange {
            didChange = false
            for layer in layers {
                guard layer.matteMode != .none,
                      let matteSource = layer.matteSourceLayerID else { continue }

                if expanded.contains(layer.id) && !expanded.contains(matteSource) {
                    guard !lockedSet.contains(matteSource) else { return [] }
                    expanded.insert(matteSource)
                    didChange = true
                }

                if expanded.contains(matteSource) && !expanded.contains(layer.id) {
                    guard !lockedSet.contains(layer.id) else { return [] }
                    expanded.insert(layer.id)
                    didChange = true
                }
            }
        }

        let ascendingLayers = layers.sorted { $0.stackIndex < $1.stackIndex }
        return ascendingLayers.filter { expanded.contains($0.id) }.map(\.id)
    }

    private func currentMovableSelectionBlock() -> (ids: [UUID], displayStart: Int, displayCount: Int)? {
        let expanded = expandedMovableIDs(from: Array(selectedLayerIDs))
        guard !expanded.isEmpty else { return nil }

        let selectionSet = Set(expanded)
        let displayOrder = layers.map(\.id)
        let indices = displayOrder.enumerated().compactMap { offset, id -> Int? in
            selectionSet.contains(id) ? offset : nil
        }

        guard let start = indices.min() else { return nil }
        let blockDisplay = displayOrder.filter { selectionSet.contains($0) }
        return (ids: expanded, displayStart: start, displayCount: blockDisplay.count)
    }

    private func destinationIndex(originalAscending: [UUID],
                                  movingAscending: [UUID],
                                  desiredAscending: [UUID]) -> Int? {
        let movingSet = Set(movingAscending)
        var base = originalAscending.filter { !movingSet.contains($0) }

        guard desiredAscending.count == originalAscending.count else { return nil }

        for index in 0...base.count {
            var simulation = base
            simulation.insert(contentsOf: movingAscending, at: index)
            if simulation == desiredAscending {
                return index
            }
        }

        return nil
    }

    private func layersAreEqual(_ lhs: [LayerSummary], _ rhs: [LayerSummary]) -> Bool {
        return lhs == rhs
    }

    private func inspectorStatesAreEqual(_ lhs: ClipInspectorState?, _ rhs: ClipInspectorState?) -> Bool {
        return lhs == rhs
    }
    
    // MARK: - A/V Sync Diagnostics
    
    func toggleDiagnostics() {
        if isDiagnosticsActive {
            stopDiagnostics()
        } else {
            startDiagnostics()
        }
    }
    
    func startDiagnostics() {
        AVSyncDiagnostics.shared.startSession()
        isDiagnosticsActive = true
        print("🔬 [Workspace] A/V Sync Diagnostics STARTED")
        print("   Play for 5 seconds, then press the same key to stop and see report")
    }
    
    func stopDiagnostics() {
        AVSyncDiagnostics.shared.stopSession()
        isDiagnosticsActive = false
        print("🔬 [Workspace] A/V Sync Diagnostics STOPPED")
    }
}

enum PanelFocus: String {
    case projectEffects
    case layers
    case viewer
    case timeline
}

struct LayerSummary: Identifiable, Hashable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var isSolo: Bool
    var isLocked: Bool
    var labelColor: LayerLabelColor
    var stackIndex: Int
    var blendMode: BlendMode
    var matteMode: TrackMatteMode
    var matteSourceLayerID: UUID?
    var matteSourceClipID: UUID?
    var usesLayerAbove: Bool
    var activeClipID: UUID?
    var activeClipName: String?
    var hideAsRender: Bool
    var matteTargets: [MatteTargetInfo]

    var isMatteSource: Bool { !matteTargets.isEmpty }
    var isMatteConsumer: Bool { matteMode != .none }
    var matteSelection: MatteSourceSelection {
        if usesLayerAbove { return .layerAbove }
        if let clipID = matteSourceClipID { return .clip(clipID) }
        return .none
    }

    init(id: UUID,
         name: String,
         isVisible: Bool,
         isSolo: Bool,
         isLocked: Bool,
         labelColor: LayerLabelColor,
         stackIndex: Int,
         blendMode: BlendMode,
         matteMode: TrackMatteMode,
         matteSourceLayerID: UUID? = nil,
         matteSourceClipID: UUID? = nil,
         usesLayerAbove: Bool = false,
         activeClipID: UUID? = nil,
         activeClipName: String? = nil,
         hideAsRender: Bool = false,
         matteTargets: [MatteTargetInfo] = []) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.labelColor = labelColor
        self.stackIndex = stackIndex
        self.blendMode = blendMode
        self.matteMode = matteMode
        self.matteSourceLayerID = matteSourceLayerID
        self.matteSourceClipID = matteSourceClipID
        self.usesLayerAbove = usesLayerAbove
        self.activeClipID = activeClipID
        self.activeClipName = activeClipName
        self.hideAsRender = hideAsRender
        self.matteTargets = matteTargets
    }

    init(track: Track) {
        self.id = track.id
        self.name = track.name
        self.isVisible = !track.muted
        self.isSolo = track.solo
        self.isLocked = track.locked
        self.labelColor = LayerLabelColor.fromHex(track.colorHex)
        self.stackIndex = track.stackIndex
        self.blendMode = track.blendMode
        self.matteMode = .none
        self.matteSourceLayerID = nil
        self.matteSourceClipID = nil
        self.usesLayerAbove = false
        self.activeClipID = nil
        self.activeClipName = nil
        self.hideAsRender = false
        self.matteTargets = []
    }

    static let demoLayers: [LayerSummary] = [
        LayerSummary(id: UUID(),
                     name: "Intro.mov",
                     isVisible: true,
                     isSolo: false,
                     isLocked: false,
                     labelColor: .aqua,
                     stackIndex: 3,
                     blendMode: .normal,
                     matteMode: .none),
        LayerSummary(id: UUID(),
                     name: "Title Matte",
                     isVisible: true,
                     isSolo: false,
                     isLocked: false,
                     labelColor: .blue,
                     stackIndex: 2,
                     blendMode: .normal,
                     matteMode: .alpha,
                     matteSourceLayerID: nil),
        LayerSummary(id: UUID(),
                     name: "BG Gradient",
                     isVisible: true,
                     isSolo: false,
                     isLocked: true,
                     labelColor: .purple,
                     stackIndex: 1,
                     blendMode: .normal,
                     matteMode: .none)
    ]
}

struct MatteTargetInfo: Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct MatteSourceOption: Identifiable, Hashable {
    let id: UUID        // Clip ID
    let layerID: UUID
    let name: String
}

enum MatteSourceSelection: Hashable {
    case none
    case layerAbove
    case clip(UUID)
}

struct ClipInspectorState: Identifiable, Equatable {
    var id: UUID { clipID }
    let clipID: UUID
    let layerID: UUID
    let layerName: String
    let transform: Transform2D
    let matteMode: TrackMatteMode
    let matteSourceClipID: UUID?
    let useLayerAbove: Bool
    let hideAsRender: Bool
    let availableSources: [MatteSourceOption]
    let layerAboveOption: MatteSourceOption?
    let isMatteSource: Bool
}

enum LayerLabelColor: String, CaseIterable {
    case red, orange, yellow, green, aqua, blue, purple, pink

    static func fromHex(_ hex: String) -> LayerLabelColor {
        switch hex.uppercased() {
        case "#FF0000": return .red
        case "#FFA500": return .orange
        case "#FFFF00": return .yellow
        case "#00FF00": return .green
        case "#00FFFF": return .aqua
        case "#0000FF": return .blue
        case "#800080": return .purple
        case "#FFC0CB": return .pink
        default: return .blue
        }
    }
}

struct ProjectItem: Identifiable, Hashable {
    let id: UUID
    let name: String
    let type: ItemType
    var childItems: [ProjectItem]? = nil

    enum ItemType {
        case folder
        case footage
        case composition
    }

    static let demoProject: [ProjectItem] = [
        ProjectItem(id: UUID(), name: "Main Compositions", type: .folder, childItems: [
            ProjectItem(id: UUID(), name: "Celeste_Main", type: .composition),
            ProjectItem(id: UUID(), name: "LowerThird", type: .composition)
        ]),
        ProjectItem(id: UUID(), name: "Footage", type: .folder, childItems: [
            ProjectItem(id: UUID(), name: "Intro.mov", type: .footage),
            ProjectItem(id: UUID(), name: "Particles.mov", type: .footage)
        ])
    ]
}
