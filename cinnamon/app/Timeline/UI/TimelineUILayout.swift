import SwiftUI
import AppKit
import AVFoundation
import Foundation

enum TimelineScrollMode: String, CaseIterable {
    case smooth
    case page

    static var supported: [TimelineScrollMode] { [.page] }

    var label: String {
        switch self {
        case .smooth: return "Smooth"
        case .page: return "Page"
        }
    }
}

enum TimelineZoomAnchor: String, CaseIterable {
    case playhead
    case pointer

    var label: String {
        switch self {
        case .playhead: return "Playhead"
        case .pointer: return "Pointer"
        }
    }
}

struct TimelineUILayout: View {
    @ObservedObject var controller: TimelineController
    let layers: [LayerSummary]
    let layerDuration: TimeInterval
    let selectedLayerIDs: Set<UUID>
    let onLayerTap: (UUID) -> Void
    let onBringForward: () -> Void
    let onSendBackward: () -> Void
    let onBringToFront: () -> Void
    let onSendToBack: () -> Void
    let onReorderLayers: ([UUID], Int) -> Void
    @State private var viewport = TimelineViewport(visibleStart: 0, visibleDuration: 10.0) // Show full timeline
    @StateObject private var gestureRecognizer = TimelineGestureRecognizer()
    @State private var zoomLevel: Double = 1.0 // Start with full view
    @State private var hasUserAdjustedZoom = false
    @State private var lastKnownWidth: CGFloat = 1
    @State private var isScrubbingPlayhead = false
    @State private var lastPanTranslation: CGFloat = 0
    @State private var isPanningViewport = false
    @State private var pointerAnchorTime: TimeInterval = 0
    @State private var lastPageScrollDirection: Int = 0
    @State private var autoPanDirection: Int = 0
    @State private var autoPanIntensity: Double = 0
    @State private var autoPanTimer: Timer?
    @AppStorage("timeline.autoScrollMode") private var scrollModeRaw = TimelineScrollMode.page.rawValue
    @AppStorage("timeline.zoomAnchor") private var zoomAnchorRaw = TimelineZoomAnchor.playhead.rawValue
    @AppStorage("timeline.audioTimeUnits") private var audioTimeUnitsEnabled: Bool = false
    @State private var draggingLayerID: UUID?
    @State private var draggingBlockIDs: [UUID] = []
    @State private var dragStartIndex: Int?
    @State private var dropDisplayIndex: Int?

    var body: some View {
        GeometryReader { mainGeo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    timeRulerSection()
                        .frame(height: 32)

                    timelineCanvasSection(availableWidth: mainGeo.size.width)

                    transportSection()
                        .frame(height: 44)
                }

                // CRITICAL FIX (Bug #14 Part 6): Separate PlayheadOverlay View!
                // BEFORE: controller.playheadTime was read directly in body → re-rendered ENTIRE timeline (3 layers)
                // AFTER: Separate view with its own controller observation only re-renders playhead overlay
                // This prevents "Layer ... segments" logs 3x per frame → no more flicker/lag!
                PlayheadOverlayView(
                    playheadTime: controller.playheadTime,
                    viewport: viewport,
                    viewportWidth: mainGeo.size.width,
                    viewportHeight: mainGeo.size.height,
                    color: playheadColor
                )
            }
        }
        .timelineKeyboardShortcuts(controller: controller,
                                   bringForward: onBringForward,
                                   sendBackward: onSendBackward,
                                   bringToFront: onBringToFront,
                                   sendToBack: onSendToBack)
        .onAppear {
            if scrollModeRaw == TimelineScrollMode.smooth.rawValue {
                scrollModeRaw = TimelineScrollMode.page.rawValue
            }
            updateViewport(width: lastKnownWidth)
            TimelineTelemetry.shared.updateScrollMode(scrollMode)
            TimelineTelemetry.shared.setAudioUnitsEnabled(audioTimeUnitsEnabled)
        }
        .onDisappear {
            stopAutoPan()
        }
        .onChange(of: controller.composition.duration, initial: false) { _, _ in
            updateViewport(width: lastKnownWidth)
        }
        .onChange(of: controller.playheadTime, initial: false) { _, _ in
            // Auto-scroll only during scrubbing, NOT during playback
            // This keeps the timeline stable while playing
            if transportState == .scrubbing {
                ensurePlayheadVisible()
            }
            // During playback, CTI moves but timeline stays still
        }
        .onChange(of: zoomLevel, initial: false) { _, _ in
            recalculateVisibleDuration(anchor: currentZoomAnchorTime(default: controller.playheadTime))
            ensurePlayheadVisible()
        }
        .onChange(of: scrollModeRaw, initial: false) { _, _ in
            TimelineTelemetry.shared.updateScrollMode(scrollMode)
        }
        .onChange(of: audioTimeUnitsEnabled, initial: false) { _, newValue in
            TimelineTelemetry.shared.setAudioUnitsEnabled(newValue)
            recalculateVisibleDuration(anchor: currentZoomAnchorTime(default: controller.playheadTime))
            ensurePlayheadVisible()
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        updateViewport(width: geo.size.width)
                    }
                    .onChange(of: geo.size.width) { newWidth in
                        updateViewport(width: newWidth)
                    }
            }
        )
    }

    private var maxZoomLevel: Double { 64 }
    private var minZoomLevel: Double { 0.1 }

    private var scrollMode: TimelineScrollMode {
        let resolved = TimelineScrollMode(rawValue: scrollModeRaw) ?? .page
        return resolved == .smooth ? .page : resolved
    }

    private var transportState: TransportPlaybackState { controller.transportState }
    // Auto-scroll ONLY during scrubbing, never during playback
    private var allowsAutoScroll: Bool { transportState == .scrubbing }
    // Allow manual viewport panning during scrubbing
    private var allowsDragPan: Bool { isScrubbingPlayhead || transportState == .scrubbing }

    private var zoomAnchorMode: TimelineZoomAnchor {
        TimelineZoomAnchor(rawValue: zoomAnchorRaw) ?? .playhead
    }

    private var playheadColor: Color {
        transportState == .scrubbing ? .yellow : .red
    }

    private var zoomControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { zoomLevel },
                set: { newValue in
                    hasUserAdjustedZoom = true
                    zoomLevel = max(minZoomLevel, min(maxZoomLevel, newValue))
                }),
                   in: minZoomLevel...maxZoomLevel)
                .frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(String(format: "%.2fs", viewport.visibleDuration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timeRulerSection() -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            TimelineRulerView(playheadTime: controller.playheadTime,
                              workArea: controller.composition.workArea,
                              viewport: viewport,
                              width: width)
                .overlay(
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(totalWidth: width))
                )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func timelineCanvasSection(availableWidth: CGFloat) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            timelineLayersStack(availableWidth: availableWidth)
        }
        .background(Color.black.opacity(0.06))
        .overlay(alignment: .topLeading) {
            debugOverlay
        }
    }

    private func timelineLayersStack(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                if dropDisplayIndex == index, draggingLayerID != nil {
                    dropIndicatorView()
                }

                timelineTrackLane(for: layer, availableWidth: availableWidth)
            }

            if dropDisplayIndex == layers.count, draggingLayerID != nil {
                dropIndicatorView()
            }
        }
        .frame(minWidth: availableWidth, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 0) // No horizontal padding so clips align with ruler
    }

    private func timelineTrackLane(for layer: LayerSummary, availableWidth: CGFloat) -> some View {
        let segments = controller.segments(for: layer.id, duration: layerDuration)
        // Debug logging removed - was causing console spam during playback
        return TimelineTrackLane(layerID: layer.id,
                          segments: segments,
                          viewport: viewport,
                          availableWidth: availableWidth,
                          isSelected: selectedLayerIDs.contains(layer.id),
                          isLocked: layer.isLocked,
                          isBeingDragged: draggingBlockIDs.contains(layer.id),
                          frameDuration: controller.composition.frameTimebase.frameDuration.seconds,
                          gestureRecognizer: gestureRecognizer,
                          onTap: { tappedLayerID in
                              onLayerTap(tappedLayerID)
                          },
                          onMove: { clipID, delta in
                              controller.moveClip(id: clipID, delta: delta)
                          },
                          onBeginReorder: handleLaneReorderBegan,
                          onUpdateReorder: handleLaneReorderChanged,
                          onEndReorder: handleLaneReorderEnded,
                          onSlip: { clipID, delta in
                              controller.slipClip(id: clipID, delta: delta)
                          },
                          onSlide: { clipID, delta in
                              controller.slideClip(id: clipID, delta: delta)
                          },
                          onTrimIn: { clipID, delta in
                              controller.trimInClip(id: clipID, delta: delta)
                          },
                          onTrimOut: { clipID, delta in
                              controller.trimOutClip(id: clipID, delta: delta)
                          })
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading) {
            Text("Debug: \(layers.count) layers")
                .font(.caption)
                .foregroundColor(.yellow)
            ForEach(layers.prefix(3)) { layer in
                let segments = controller.segments(for: layer.id, duration: layerDuration)
                if let firstClip = segments.first(where: { $0.clip != nil })?.clip {
                    Text("Clip: \(firstClip.name) @ \(String(format: "%.1f", firstClip.dstStart))-\(String(format: "%.1f", firstClip.dstEnd))s")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
            Text("Viewport: \(String(format: "%.1f", viewport.visibleDuration))s")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(4)
        .background(Color.black.opacity(0.8))
        .cornerRadius(4)
    }

    private var laneRowHeight: CGFloat { 44 }
    private var laneSpacing: CGFloat { 4 }

    private func dropIndicatorView() -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.7))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 0)
    }

    private func handleLaneReorderBegan(layerID: UUID) {
        guard draggingLayerID == nil else { return }
        guard let block = dragBlock(for: layerID), !block.ids.isEmpty else { return }
        draggingLayerID = layerID
        draggingBlockIDs = block.ids
        dragStartIndex = block.startIndex
        dropDisplayIndex = block.startIndex
    }

    private func handleLaneReorderChanged(layerID: UUID, translation: CGFloat) {
        guard draggingLayerID == layerID,
              let startIndex = dragStartIndex,
              !draggingBlockIDs.isEmpty else { return }

        let stepSize = laneRowHeight + laneSpacing
        let offset = translation / stepSize
        let steps = Int(offset.rounded())
        if steps == 0 && abs(translation) < stepSize * 0.5 {
            return
        }
        let limit = max(0, layers.count - draggingBlockIDs.count)
        var target = startIndex + steps
        target = max(0, min(target, limit))
        if target > startIndex || (target == startIndex && translation > 0) {
            dropDisplayIndex = min(target + draggingBlockIDs.count, layers.count)
        } else {
            dropDisplayIndex = max(target, 0)
        }
    }

    private func handleLaneReorderEnded(layerID: UUID, translation: CGFloat) {
        defer { resetDragState() }
        guard draggingLayerID == layerID,
              let startIndex = dragStartIndex,
              !draggingBlockIDs.isEmpty else { return }

        let stepSize = laneRowHeight + laneSpacing
        let offset = translation / stepSize
        let steps = Int(offset.rounded())
        if steps == 0 && abs(translation) < stepSize * 0.5 {
            return
        }
        let limit = max(0, layers.count - draggingBlockIDs.count)
        var target = startIndex + steps
        target = max(0, min(target, limit))

        if target != startIndex {
            onReorderLayers(draggingBlockIDs, target)
        }
    }

    private func resetDragState() {
        draggingLayerID = nil
        draggingBlockIDs = []
        dragStartIndex = nil
        dropDisplayIndex = nil
    }

    private func dragBlock(for layerID: UUID) -> (ids: [UUID], startIndex: Int)? {
        guard let sourceLayer = layers.first(where: { $0.id == layerID }), !sourceLayer.isLocked else {
            return nil
        }

        let displayOrder = layers.map(\.id)
        let selection = selectedLayerIDs
        let blockIDs: [UUID]

        if selection.contains(layerID) {
            blockIDs = displayOrder.filter { selection.contains($0) }
        } else {
            blockIDs = [layerID]
        }

        guard !blockIDs.isEmpty else { return nil }
        let lockedIDs = Set(layers.filter { $0.isLocked }.map(\.id))
        if blockIDs.contains(where: { lockedIDs.contains($0) }) {
            return nil
        }

        let indices = displayOrder.enumerated().compactMap { offset, id -> Int? in
            blockIDs.contains(id) ? offset : nil
        }

        guard let startIndex = indices.min() else { return nil }
        return (blockIDs, startIndex)
    }

    private func transportSection() -> some View {
        VStack(spacing: 4) {
            // Timeline operations toolbar
            timelineOperationsToolbar()
                .padding(.vertical, 2)

            Divider()

            // Transport controls
            HStack {
                Button(action: controller.stepBackward) {
                    Image(systemName: "backward.frame")
                }
                Button(action: controller.requestPause) {
                    Image(systemName: "pause.fill")
                }
                Button(action: { controller.requestPlay(rate: 1.0, completion: nil) }) {
                    Image(systemName: "play.fill")
                }
                Button(action: controller.stepForward) {
                    Image(systemName: "forward.frame")
                }
                Spacer()
            Slider(value: Binding(get: { controller.playheadTime }, set: { controller.requestTime($0, completion: nil) }),
                   in: 0...controller.composition.duration)
                .frame(maxWidth: 320)

            Divider().frame(height: 16)

            zoomControl

            Menu {
                ForEach(TimelineScrollMode.supported, id: \.rawValue) { mode in
                    Button(mode.label) { scrollModeRaw = mode.rawValue }
                }
            } label: {
                Label("Scroll", systemImage: "arrow.left.and.right")
                    .labelStyle(.iconOnly)
                    .help("Auto-scroll mode")
            }

            Menu {
                ForEach(TimelineZoomAnchor.allCases, id: \.rawValue) { anchor in
                    Button(anchor.label) { zoomAnchorRaw = anchor.rawValue }
                }
            } label: {
                Label("Anchor", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .help("Zoom anchor")
            }

            Toggle(isOn: $audioTimeUnitsEnabled) {
                Image(systemName: "waveform")
                    .help("Toggle audio time units")
            }
            .toggleStyle(.button)
            }
            .padding(.horizontal, 12)
            .buttonStyle(.plain)
            .disabled(controller.playbackTimeline.isEmpty)
        }
    }

    private func timelineOperationsToolbar() -> some View {
        HStack(spacing: 12) {
            // Blade/Split tool
            Button(action: {
                controller.splitClip(at: controller.playheadTime)
            }) {
                Label("Split", systemImage: "scissors")
                    .labelStyle(.titleAndIcon)
            }
            .help("Split clip at playhead (S)")
            .keyboardShortcut("s", modifiers: [])

            // Delete
            Button(action: {
                controller.deleteClip(at: controller.playheadTime)
            }) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .help("Delete clip at playhead")

            Divider().frame(height: 16)

            // Set In point
            Button(action: {
                controller.setWorkIn(at: controller.playheadTime)
            }) {
                Label("Set In", systemImage: "arrow.down.to.line")
                    .labelStyle(.titleAndIcon)
            }
            .help("Set work area in point (I)")
            .keyboardShortcut("i", modifiers: [])

            // Set Out point
            Button(action: {
                controller.setWorkOut(at: controller.playheadTime)
            }) {
                Label("Set Out", systemImage: "arrow.up.to.line")
                    .labelStyle(.titleAndIcon)
            }
            .help("Set work area out point (O)")
            .keyboardShortcut("o", modifiers: [])

            // Clear work area
            Button(action: controller.clearWorkArea) {
                Label("Clear Work", systemImage: "xmark.rectangle")
                    .labelStyle(.titleAndIcon)
            }
            .help("Clear work area")

            Divider().frame(height: 16)

            // Lift
            Button(action: {
                controller.lift()
            }) {
                Label("Lift", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .help("Lift selection (remove without closing gap)")

            // Extract
            Button(action: {
                controller.extract()
            }) {
                Label("Extract", systemImage: "square.and.arrow.up.fill")
                    .labelStyle(.titleAndIcon)
            }
            .help("Extract selection (remove and close gap)")

            Divider().frame(height: 16)

            // Undo
            Button(action: controller.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
            .help("Undo last action (Cmd+Z)")
            .keyboardShortcut("z", modifiers: [.command])

            // Redo
            Button(action: controller.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
                    .labelStyle(.titleAndIcon)
            }
            .help("Redo last action (Cmd+Shift+Z)")
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer()
        }
        .buttonStyle(.plain)
    }

    private func updateViewport(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }

        lastKnownWidth = width
        viewport.pixelWidth = width
        viewport.frameRate = controller.composition.frameRate

        let compositionDuration = controller.composition.duration
        if compositionDuration > 0, !hasUserAdjustedZoom {
            let defaultVisibleDuration = compositionDuration
            let targetZoom = max(minZoomLevel, min(maxZoomLevel, compositionDuration / max(defaultVisibleDuration, 0.001)))
            if abs(targetZoom - zoomLevel) > 0.001 {
                zoomLevel = targetZoom
            }
        }

        recalculateVisibleDuration(resetIfNeeded: true, anchor: currentZoomAnchorTime(default: controller.playheadTime))
        ensurePlayheadVisible()
    }

    private func recalculateVisibleDuration(resetIfNeeded: Bool = false, anchor: TimeInterval? = nil) {
        let compositionDuration = controller.composition.duration

        guard compositionDuration > 0 else {
            viewport.visibleStart = 0
            viewport.visibleDuration = 10
            return
        }

        let timebase = controller.composition.frameTimebase
        let frameDuration = max(timebase.frameDuration.seconds, 1e-6)
        let fps = max(timebase.framesPerSecond.doubleValue, 0.0001)
        let oldStart = viewport.visibleStart
        let oldDuration = max(viewport.visibleDuration, 0.0001)
        let targetAnchor = anchor ?? controller.playheadTime
        let clampedAnchor = min(max(targetAnchor, 0), compositionDuration)
        let anchorRatio = min(max((clampedAnchor - oldStart) / oldDuration, 0), 1)

        let audioMinWindow = 0.01
        let width = max(Double(lastKnownWidth), 1)
        let span = compositionDuration / max(zoomLevel, minZoomLevel)
        var clampedSpan = min(max(span, frameDuration), compositionDuration)

        if audioTimeUnitsEnabled {
            // Clamp px/sec for audio zoom domain while keeping at least video frame duration.
            let pxPerSecond = width / max(clampedSpan, frameDuration)
            if pxPerSecond > 20000 {
                clampedSpan = max(width / 20000.0, frameDuration)
            }
            let minWindow = max(frameDuration, audioMinWindow)
            clampedSpan = max(clampedSpan, minWindow)
        } else {
            let pxPerSecond = width / max(clampedSpan, frameDuration)
            let pxPerFrame = pxPerSecond / fps
            let ppfMin: Double = 8
            let ppfMax: Double = 64

            if pxPerFrame < ppfMin {
                let maxDuration = width / (fps * ppfMin)
                clampedSpan = min(max(maxDuration, frameDuration), compositionDuration)
            } else if pxPerFrame > ppfMax && clampedSpan > frameDuration + 1e-6 {
                let minDuration = width / (fps * ppfMax)
                clampedSpan = min(max(minDuration, frameDuration), compositionDuration)
            }
        }

        clampedSpan = min(max(clampedSpan, frameDuration), compositionDuration)

        viewport.visibleDuration = clampedSpan
        if clampedSpan > 0 {
            let pxPerSecond = width / clampedSpan
            let pxPerFrameValue = pxPerSecond / fps
            TimelineTelemetry.shared.updatePxPerFrame(pxPerFrameValue)
        }

        let proposedStart = clampedAnchor - anchorRatio * clampedSpan
        if resetIfNeeded {
            viewport.visibleStart = max(0, proposedStart)
        } else {
            viewport.visibleStart = proposedStart
        }

        clampVisibleStart()
        alignVisibleStartToFrame()
    }

    private func clampVisibleStart() {
        let compositionDuration = controller.composition.duration
        if compositionDuration <= viewport.visibleDuration {
            viewport.visibleStart = 0
        } else {
            let maxStart = compositionDuration - viewport.visibleDuration
            viewport.visibleStart = min(max(0, viewport.visibleStart), maxStart)
        }
    }

    private func ensurePlayheadVisible() {
        let compositionDuration = controller.composition.duration
        guard compositionDuration > 0 else { return }

        guard allowsAutoScroll else {
            lastPageScrollDirection = 0
            clampVisibleStart()
            alignVisibleStartToFrame()
            return
        }

        let time = controller.playheadTime
        let duration = viewport.visibleDuration
        let epsilon: TimeInterval = 1e-6

        if compositionDuration <= duration + epsilon {
            viewport.visibleStart = 0
            return
        }

        guard scrollMode == .page else {
            lastPageScrollDirection = 0
            clampVisibleStart()
            alignVisibleStartToFrame()
            return
        }

        let enterRight = viewport.visibleStart + duration * 0.80
        let releaseRight = viewport.visibleStart + duration * 0.75
        let enterLeft = viewport.visibleStart + duration * 0.20
        let releaseLeft = viewport.visibleStart + duration * 0.25

        if lastPageScrollDirection <= 0 && time > enterRight + epsilon {
            let newStart = min(time - duration * 0.2, compositionDuration - duration)
            viewport.visibleStart = max(0, newStart)
            lastPageScrollDirection = 1
            TimelineTelemetry.shared.recordAutoScrollResult(true)
        } else if lastPageScrollDirection >= 0 && time < enterLeft - epsilon {
            let newStart = max(0, time - duration * 0.8)
            viewport.visibleStart = min(newStart, compositionDuration - duration)
            lastPageScrollDirection = -1
            TimelineTelemetry.shared.recordAutoScrollResult(true)
        } else {
            if lastPageScrollDirection == 1 && time < releaseRight {
                lastPageScrollDirection = 0
            }
            if lastPageScrollDirection == -1 && time > releaseLeft {
                lastPageScrollDirection = 0
            }
        }

        clampVisibleStart()
        alignVisibleStartToFrame()
    }

    private func panViewportIfNeeded(for pointerX: CGFloat, totalWidth: CGFloat) {
        guard allowsDragPan, totalWidth > 0 else {
            stopAutoPan()
            return
        }

        let guardFraction: CGFloat = 0.15
        let guardWidth = totalWidth * guardFraction
        guard guardWidth > 0 else { return }

        let leftBound = guardWidth
        let rightBound = totalWidth - guardWidth
        let shiftFactor = viewport.visibleDuration * 0.04
        var updated = false

        if pointerX < leftBound {
            let ratio = min(1, max(0, (leftBound - pointerX) / guardWidth))
            let delta = shiftFactor * Double(ratio)
            viewport.visibleStart = max(0, viewport.visibleStart - delta)
            updated = true
            startAutoPan(direction: -1, intensity: Double(max(0.1, ratio)))
        } else if pointerX > rightBound {
            let ratio = min(1, max(0, (pointerX - rightBound) / guardWidth))
            let delta = shiftFactor * Double(ratio)
            let maxStart = max(0, controller.composition.duration - viewport.visibleDuration)
            viewport.visibleStart = min(maxStart, viewport.visibleStart + delta)
            updated = true
            startAutoPan(direction: 1, intensity: Double(max(0.1, ratio)))
        } else {
            stopAutoPan()
        }

        if updated {
            clampVisibleStart()
            alignVisibleStartToFrame()
        }
    }

    private func currentZoomAnchorTime(default defaultTime: TimeInterval) -> TimeInterval {
        switch zoomAnchorMode {
        case .playhead:
            return defaultTime
        case .pointer:
            return min(max(pointerAnchorTime, 0), controller.composition.duration)
        }
    }

    private func alignVisibleStartToFrame() {
        guard !audioTimeUnitsEnabled else { return }
        let timebase = controller.composition.frameTimebase
        let aligned = timebase.quantize(viewport.visibleStart, rounding: .floor)
        let maxStart = max(0, controller.composition.duration - viewport.visibleDuration)
        viewport.visibleStart = min(max(0, aligned), maxStart)
    }

    private func compositionFrameDuration() -> Double {
        controller.composition.frameTimebase.frameDuration.seconds
    }

    private func scrubGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let clampedX = min(max(0, value.location.x), totalWidth)
                let targetTime = viewport.time(forX: clampedX, totalWidth: totalWidth)

                if !isScrubbingPlayhead {
                    isScrubbingPlayhead = true
                    gestureRecognizer.begin(.scrubTimeline)
                    if transportState != .scrubbing {
                        controller.beginScrub()
                    }
                }

                panViewportIfNeeded(for: value.location.x, totalWidth: totalWidth)
                controller.scrub(to: targetTime)
            }
            .onEnded { value in
                let clampedX = min(max(0, value.location.x), totalWidth)
                let targetTime = viewport.time(forX: clampedX, totalWidth: totalWidth)
                panViewportIfNeeded(for: value.location.x, totalWidth: totalWidth)
                controller.scrub(to: targetTime)
                controller.endScrub(resumeIfWanted: false)

                gestureRecognizer.end()
                isScrubbingPlayhead = false
                stopAutoPan()
            }
    }

    private func panGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard allowsDragPan else {
                    lastPanTranslation = 0
                    isPanningViewport = false
                    stopAutoPan()
                    return
                }
                let secondsPerPixel = viewport.visibleDuration / max(totalWidth, 1)
                if !isPanningViewport {
                    isPanningViewport = true
                    lastPanTranslation = value.translation.width
                }

                let deltaPixels = value.translation.width - lastPanTranslation
                lastPanTranslation = value.translation.width
                let deltaSeconds = -Double(deltaPixels) * Double(secondsPerPixel)

                if abs(deltaSeconds) > 0.0001 {
                    adjustVisibleStart(by: deltaSeconds)
                }
            }
            .onEnded { _ in
                guard allowsDragPan else {
                    lastPanTranslation = 0
                    isPanningViewport = false
                    stopAutoPan()
                    return
                }
                lastPanTranslation = 0
                isPanningViewport = false
                stopAutoPan()
            }
    }

    private func adjustVisibleStart(by deltaSeconds: Double) {
        guard controller.composition.duration > 0 else { return }
        let maxStart = max(0, controller.composition.duration - viewport.visibleDuration)
        let newStart = min(max(0, viewport.visibleStart + deltaSeconds), maxStart)
        viewport.visibleStart = newStart
        clampVisibleStart()
        alignVisibleStartToFrame()
    }

    private func startAutoPan(direction: Int, intensity: Double) {
        guard direction != 0 else {
            stopAutoPan()
            return
        }

        autoPanDirection = direction
        autoPanIntensity = max(0.05, min(intensity, 0.8))

        if autoPanTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                autoPanTick()
            }
            autoPanTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAutoPan() {
        autoPanDirection = 0
        autoPanIntensity = 0
        autoPanTimer?.invalidate()
        autoPanTimer = nil
    }

    private func autoPanTick() {
        guard autoPanDirection != 0, allowsDragPan else {
            stopAutoPan()
            return
        }

        let step = viewport.visibleDuration * 0.04 * autoPanIntensity
        let delta = Double(autoPanDirection) * step
        adjustVisibleStart(by: delta)
    }
}

// MARK: - Subviews

private struct TimelineTrackLane: View {
    let layerID: UUID
    let segments: [TimelineSegment]
    let viewport: TimelineViewport
    let availableWidth: CGFloat
    // CRITICAL FIX (Bug #14 Part 4): Removed `playhead` parameter!
    // This parameter was NEVER USED in the view body, but caused SwiftUI to re-render
    // ALL timeline lanes 60+ times/second during scrubbing → MainActor freeze!
    // Playhead is already drawn as separate overlay (lines 78-95), so this was redundant.
    let isSelected: Bool
    let isLocked: Bool
    let isBeingDragged: Bool
    let frameDuration: TimeInterval
    @ObservedObject var gestureRecognizer: TimelineGestureRecognizer
    let onTap: (UUID) -> Void
    let onMove: (UUID, TimeInterval) -> Void
    let onBeginReorder: (UUID) -> Void
    let onUpdateReorder: (UUID, CGFloat) -> Void
    let onEndReorder: (UUID, CGFloat) -> Void
    let onSlip: (UUID, TimeInterval) -> Void
    let onSlide: (UUID, TimeInterval) -> Void
    let onTrimIn: ((UUID, TimeInterval) -> Void)?
    let onTrimOut: ((UUID, TimeInterval) -> Void)?

    @State private var reorderGestureActive = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background layer that can be tapped (gaps between clips) and handles vertical reordering
            Color.clear
                .frame(width: availableWidth, height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap(layerID)
                }
                .gesture(laneReorderGesture) // Allow vertical dragging for reordering on background

            // Clips layer - positioned on top with their own gestures
            ForEach(segments) { segment in
                if let clip = segment.clip {
                    let clipStart = segment.start
                    let clipEnd = segment.end
                    let clipRect = viewport.rect(start: clipStart, end: clipEnd, totalWidth: availableWidth)

                    if clipRect.maxX >= -50, clipRect.minX <= availableWidth + 50 {
                        TimelineClipView(clip: clip,
                                         clipRect: clipRect,
                                         isTrackSelected: isSelected,
                                         isLocked: isLocked,
                                         viewport: viewport,
                                         availableWidth: availableWidth,
                                         frameDuration: frameDuration,
                                         gestureRecognizer: gestureRecognizer,
                                         onMove: onMove,
                                         onSlip: onSlip,
                                         onSlide: onSlide,
                                         onTrimIn: onTrimIn,
                                         onTrimOut: onTrimOut)
                    }
                }
            }
        }
        .frame(width: availableWidth, height: 44, alignment: .topLeading)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .cornerRadius(6)
        .overlay(alignment: .leading) {
            reorderHandle
        }
    }

    private var backgroundColor: Color {
        if isBeingDragged {
            return Color.accentColor.opacity(0.28)
        }
        return isSelected ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        if isBeingDragged {
            return Color.accentColor
        }
        return isSelected ? Color.accentColor : Color.clear
    }

    private var borderWidth: CGFloat {
        isBeingDragged || isSelected ? 2 : 0
    }

    private var reorderHandle: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isLocked ? Color.gray.opacity(0.25) : Color.gray.opacity(0.45))
                .frame(width: 6, height: 26)
                .padding(.leading, 6)

            if !isLocked {
                Color.clear
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
                    .gesture(reorderGesture)
            }
        }
        .frame(width: 28, height: 44, alignment: .leading)
        .padding(.leading, 2)
    }

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !isLocked else { return }
                if !reorderGestureActive {
                    reorderGestureActive = true
                    onBeginReorder(layerID)
                }
                onUpdateReorder(layerID, value.translation.height)
            }
            .onEnded { value in
                guard !isLocked else { return }
                if reorderGestureActive {
                    onEndReorder(layerID, value.translation.height)
                }
                reorderGestureActive = false
            }
    }

    private var laneReorderGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !isLocked else { return }
                let vertical = abs(value.translation.height)
                let horizontal = abs(value.translation.width)

                if !reorderGestureActive {
                    // Make it easier to initiate vertical drag - only require vertical > horizontal/2
                    if vertical <= horizontal / 2 {
                        return
                    }
                    reorderGestureActive = true
                    onBeginReorder(layerID)
                }

                onUpdateReorder(layerID, value.translation.height)
            }
            .onEnded { value in
                guard !isLocked else { return }
                if reorderGestureActive {
                    onEndReorder(layerID, value.translation.height)
                    reorderGestureActive = false
                }
            }
    }
}

private struct TimelineClipView: View {
    let clip: Clip
    let clipRect: CGRect
    let isTrackSelected: Bool
    let isLocked: Bool
    let viewport: TimelineViewport
    let availableWidth: CGFloat
    let frameDuration: TimeInterval
    @ObservedObject var gestureRecognizer: TimelineGestureRecognizer
    let onMove: (UUID, TimeInterval) -> Void
    let onSlip: (UUID, TimeInterval) -> Void
    let onSlide: (UUID, TimeInterval) -> Void
    let onTrimIn: ((UUID, TimeInterval) -> Void)?
    let onTrimOut: ((UUID, TimeInterval) -> Void)?

    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var accumulatedDelta: TimeInterval = 0
    @State private var dragMode: DragMode = .move
    @State private var isHoveringLeftEdge = false
    @State private var isHoveringRightEdge = false
    @GestureState private var dragState = CGSize.zero

    private var secondsPerPixel: Double {
        guard availableWidth > 0 else { return 0 }
        return viewport.visibleDuration / Double(availableWidth)
    }

    private enum DragMode {
        case move
        case slip
        case slide
        case trimIn
        case trimOut
    }

    private func resolveDragMode() -> DragMode {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            return .slide
        }
        if flags.contains(.option) {
            return .slip
        }
        return .move
    }

    private func gestureType(for mode: DragMode) -> TimelineGestureType {
        switch mode {
        case .move:
            return .moveLayer(clip.id)
        case .slip:
            return .slipLayer(clip.id)
        case .slide:
            return .slideLayer(clip.id)
        case .trimIn:
            return .trimLayer(clip.id, .in)
        case .trimOut:
            return .trimLayer(clip.id, .out)
        }
    }

    var body: some View {
        let fillColor = isTrackSelected ? Color.accentColor.opacity(0.7) : Color.cyan.opacity(0.6)
        let strokeColor = isTrackSelected ? Color.accentColor : Color.cyan

        // Position the clip directly without wrapper
        clipContent(fillColor: fillColor, strokeColor: strokeColor)
            .frame(width: max(clipRect.width + (dragMode == .trimOut ? dragTranslation : dragMode == .trimIn ? -dragTranslation : 0), 1), height: 38)
            .contentShape(Rectangle()) // Ensure entire clip area is responsive to gestures
            .offset(x: clipRect.minX + (dragMode == .move ? dragTranslation : dragMode == .trimIn ? dragTranslation : 0), y: 3)
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard !isLocked else { return }

                        print("Clip drag started - translation: \(value.translation)")

                        // Skip if we're already handling an edge drag
                        if isHoveringLeftEdge || isHoveringRightEdge {
                            return
                        }

                        if !isDragging {
                            isDragging = true
                            dragMode = resolveDragMode()
                            gestureRecognizer.begin(gestureType(for: dragMode))
                            accumulatedDelta = 0
                        }

                        // Update visual feedback during drag
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        print("Clip drag ended - translation: \(value.translation)")
                        if !isHoveringLeftEdge && !isHoveringRightEdge && isDragging {
                            handleDragEnd(value.translation.width)
                        }
                    }
            )
    }

    private func clipContent(fillColor: Color, strokeColor: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(strokeColor, lineWidth: isTrackSelected ? 2 : 1)
                )
                .shadow(color: isTrackSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                        radius: isTrackSelected ? 4 : 0,
                        y: isTrackSelected ? 1 : 0)

            Text(clip.name)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)

            // Resize handles at edges
            HStack(spacing: 0) {
                // Left edge handle
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8, height: 38)
                    .onHover { hovering in
                        isHoveringLeftEdge = hovering
                        if hovering && !isLocked {
                            NSCursor.resizeLeftRight.set()
                        } else if !hovering && !isHoveringRightEdge {
                            NSCursor.arrow.set()
                        }
                    }
                    .highPriorityGesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isLocked else { return }
                                if !isDragging {
                                    isDragging = true
                                    dragMode = .trimIn
                                    gestureRecognizer.begin(.trimLayer(clip.id, .in))
                                }
                                dragTranslation = value.translation.width
                            }
                            .onEnded { value in
                                handleDragEnd(value.translation.width)
                            }
                    )

                Spacer()

                // Right edge handle
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8, height: 38)
                    .onHover { hovering in
                        isHoveringRightEdge = hovering
                        if hovering && !isLocked {
                            NSCursor.resizeLeftRight.set()
                        } else if !hovering && !isHoveringLeftEdge {
                            NSCursor.arrow.set()
                        }
                    }
                    .highPriorityGesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isLocked else { return }
                                if !isDragging {
                                    isDragging = true
                                    dragMode = .trimOut
                                    gestureRecognizer.begin(.trimLayer(clip.id, .out))
                                }
                                dragTranslation = value.translation.width
                            }
                            .onEnded { value in
                                handleDragEnd(value.translation.width)
                            }
                    )
            }
        }
        .onHover { hovering in
            if isLocked {
                if !hovering {
                    gestureRecognizer.end()
                }
                return
            }
            if hovering {
                gestureRecognizer.begin(gestureType(for: resolveDragMode()))
            } else if !isDragging {
                gestureRecognizer.end()
            }
        }
    }

    private func handleDragEnd(_ translationWidth: CGFloat) {
        guard !isLocked else {
            gestureRecognizer.end()
            accumulatedDelta = 0
            dragTranslation = 0
            isDragging = false
            isHoveringLeftEdge = false
            isHoveringRightEdge = false
            dragMode = .move
            return
        }

        gestureRecognizer.end()

        // Calculate delta in seconds - let the operation handle frame quantization
        // Apply a scaling factor to make dragging more responsive
        let dragScale = 2.0 // Amplify drag movement for better responsiveness
        let deltaSeconds = Double(translationWidth) * secondsPerPixel * dragScale

        // Apply the operation if the delta is significant
        if abs(deltaSeconds) > 1e-6 {
            switch dragMode {
            case .move:
                onMove(clip.id, deltaSeconds)
            case .slip:
                onSlip(clip.id, deltaSeconds)
            case .slide:
                onSlide(clip.id, deltaSeconds)
            case .trimIn:
                onTrimIn?(clip.id, deltaSeconds)
            case .trimOut:
                onTrimOut?(clip.id, deltaSeconds)
            }
        }

        // Reset state after applying changes
        dragTranslation = 0
        isDragging = false
        isHoveringLeftEdge = false
        isHoveringRightEdge = false
        dragMode = .move
        accumulatedDelta = 0
    }
}

private struct TimelineRulerView: View {
    let playheadTime: TimeInterval
    let workArea: CMTimeRange?
    let viewport: TimelineViewport
    let width: CGFloat

    private func formatTimecode(_ seconds: TimeInterval, frameRate: Double) -> String {
        let totalFrames = Int(seconds * frameRate)
        let hours = totalFrames / (3600 * Int(frameRate))
        let minutes = (totalFrames % (3600 * Int(frameRate))) / (60 * Int(frameRate))
        let secs = (totalFrames % (60 * Int(frameRate))) / Int(frameRate)
        let frames = totalFrames % Int(frameRate)

        if hours > 0 {
            return String(format: "%01d:%02d:%02d:%02d", hours, minutes, secs, frames)
        } else if minutes > 0 {
            return String(format: "%01d:%02d:%02d", minutes, secs, frames)
        } else {
            return String(format: "%01d:%02d", secs, frames)
        }
    }

    var body: some View {
        Canvas { context, size in
            if let workArea {
                let rect = viewport.rect(for: workArea, totalWidth: size.width)
                let path = Path(CGRect(x: rect.minX, y: 0, width: rect.width, height: size.height))
                context.fill(path, with: .color(Color.blue.opacity(0.1)))
            }

            let frameRate = viewport.frameRate
            let frameDuration = 1.0 / frameRate
            let startTime = viewport.visibleStart
            let endTime = viewport.visibleEnd
            let totalDuration = endTime - startTime

            let idealTickCount = 10.0
            let secondsPerTick = totalDuration / idealTickCount

            let tickInterval: TimeInterval
            if secondsPerTick < 0.5 {
                tickInterval = frameDuration * max(1, round(secondsPerTick * frameRate))
            } else if secondsPerTick < 1 {
                tickInterval = 1
            } else if secondsPerTick < 5 {
                tickInterval = round(secondsPerTick)
            } else if secondsPerTick < 10 {
                tickInterval = 5
            } else if secondsPerTick < 30 {
                tickInterval = 10
            } else if secondsPerTick < 60 {
                tickInterval = 30
            } else {
                tickInterval = 60 * ceil(secondsPerTick / 60)
            }

            var tick = floor(startTime / tickInterval) * tickInterval
            var tickIndex = 0

            while tick <= endTime {
                let x = viewport.xPosition(for: tick, totalWidth: size.width)

                if x >= 0 && x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height - 8))
                    path.addLine(to: CGPoint(x: x, y: size.height))

                    let isMajorTick = tickIndex % 5 == 0
                    if isMajorTick {
                        path.move(to: CGPoint(x: x, y: size.height - 12))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)

                        let label = formatTimecode(tick, frameRate: frameRate)
                        let text = Text(label).font(.system(size: 10, weight: .regular, design: .monospaced))
                        context.draw(text, at: CGPoint(x: x + 4, y: 10))
                    } else {
                        context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
                    }
                }

                tick += tickInterval
                tickIndex += 1
            }

            // Playhead indicator is handled in main layout

            if let workArea {
                let start = viewport.xPosition(for: workArea.start.seconds, totalWidth: size.width)
                let end = viewport.xPosition(for: workArea.end.seconds, totalWidth: size.width)

                var workAreaPath = Path()
                workAreaPath.addRect(CGRect(x: start, y: 0, width: 3, height: 4))
                workAreaPath.addRect(CGRect(x: end - 3, y: 0, width: 3, height: 4))
                context.fill(workAreaPath, with: .color(.blue.opacity(0.8)))
            }
        }
    }
}

// MARK: - Viewport support

struct TimelineViewport: Sendable {
    var visibleStart: TimeInterval = 0
    var visibleDuration: TimeInterval = 10
    var pixelWidth: CGFloat = 1920
    var zoomLevel: Double = 1
    var frameRate: Double = 30

    init(visibleStart: TimeInterval = 0,
         visibleDuration: TimeInterval = 10,
         pixelWidth: CGFloat = 1920,
         zoomLevel: Double = 1,
         frameRate: Double = 30) {
        self.visibleStart = visibleStart
        self.visibleDuration = visibleDuration
        self.pixelWidth = pixelWidth
        self.zoomLevel = zoomLevel
        self.frameRate = frameRate
    }

    var visibleEnd: TimeInterval { visibleStart + visibleDuration }

    func pixelsPerSecond(for width: CGFloat) -> CGFloat {
        let duration = max(visibleDuration, 0.001)
        return width / CGFloat(duration)
    }

    func xPosition(for time: TimeInterval, totalWidth: CGFloat) -> CGFloat {
        let ratio = (time - visibleStart) / max(visibleDuration, 0.001)
        return CGFloat(ratio) * totalWidth
    }

    func time(forX x: CGFloat, totalWidth: CGFloat) -> TimeInterval {
        guard totalWidth.isFinite, totalWidth > 0 else { return visibleStart }
        let ratio = max(0, min(1, Double(x / totalWidth)))
        return visibleStart + visibleDuration * ratio
    }

    func rect(start: TimeInterval, end: TimeInterval, totalWidth: CGFloat) -> CGRect {
        let x = xPosition(for: start, totalWidth: totalWidth)
        let width = CGFloat(max((end - start) / max(visibleDuration, 0.001), 0)) * totalWidth
        return CGRect(x: x, y: 0, width: max(width, 1), height: 40)
    }

    func rect(for timeRange: CMTimeRange, totalWidth: CGFloat) -> CGRect {
        let start = xPosition(for: timeRange.start.seconds, totalWidth: totalWidth)
        let end = xPosition(for: timeRange.end.seconds, totalWidth: totalWidth)
        return CGRect(x: start, y: 0, width: max(end - start, 1), height: 32)
    }

    var majorTickInterval: TimeInterval {
        let frameDuration = 1.0 / frameRate
        let candidate = visibleDuration / 10

        if candidate < frameDuration {
            return frameDuration
        } else if candidate < 1 {
            let framesPerTick = max(1, round(candidate * frameRate))
            return frameDuration * framesPerTick
        } else {
            let powers: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            return powers.first(where: { $0 >= candidate }) ?? 60
        }
    }
}

// MARK: - Playhead Overlay

/// Lightweight view that ONLY renders the playhead indicator.
/// This is separated from the main TimelineUILayout to prevent re-rendering
/// the entire timeline (layers, clips, etc.) when playheadTime changes.
/// Before this optimization, every playhead update triggered 3x "Layer segments" calculations.
private struct PlayheadOverlayView: View {
    let playheadTime: TimeInterval
    let viewport: TimelineViewport
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    let color: Color

    var body: some View {
        let playheadX = viewport.xPosition(for: playheadTime, totalWidth: viewportWidth)

        ZStack(alignment: .topLeading) {
            // Triangle indicator at top
            Path { path in
                path.move(to: CGPoint(x: playheadX - 6, y: 0))
                path.addLine(to: CGPoint(x: playheadX + 6, y: 0))
                path.addLine(to: CGPoint(x: playheadX, y: 8))
                path.closeSubpath()
            }
            .fill(color)
            .allowsHitTesting(false)

            // Vertical line through entire timeline
            Rectangle()
                .fill(color)
                .frame(width: 2, height: viewportHeight)
                .offset(x: playheadX - 1, y: 0)
                .allowsHitTesting(false)
        }
    }
}
