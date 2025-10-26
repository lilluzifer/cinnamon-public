import Foundation
import CoreMedia
import SwiftUI

struct AEEditContext {
    var composition: Composition
    var viewport: TimelineViewport
    var selection: Set<UUID>
}

struct TimelineEditRange {
    var start: TimeInterval
    var end: TimeInterval

    init(start: TimeInterval, end: TimeInterval) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    var duration: TimeInterval { max(0, end - start) }

    func contains(_ time: TimeInterval) -> Bool {
        start <= time && time <= end
    }
}

protocol AEEditOperation {
    var type: AEEditType { get }
    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition
}

enum AEEditError: Error {
    case clipNotFound
    case invalidState
    case overlapsDetected
    case missingRange
}

final class AEEditCommandStack {
    private var undoStack: [Composition] = []
    private var redoStack: [Composition] = []

    init() {}

    func apply(op: AEEditOperation,
               context: AEEditContext,
               snapEngine: SnapEngine) throws -> Composition {
        let newComposition = try op.execute(on: context.composition, snapEngine: snapEngine)
        undoStack.append(context.composition)
        redoStack.removeAll()
        return newComposition
    }

    func undo(current composition: Composition) -> Composition? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(composition)
        return previous
    }

    func redo(current composition: Composition) -> Composition? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(composition)
        return next
    }
}

// MARK: - Specific operations

struct AETrimInOperation: AEEditOperation {
    let clipID: UUID
    let targetTime: TimeInterval
    let rippleMode: Bool
    let type: AEEditType = .trimIn

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard let index = composition.clips.firstIndex(where: { $0.id == clipID }) else {
            throw AEEditError.clipNotFound
        }

        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        var clips = composition.clips
        var clip = clips[index]

        // Calculate new trim position
        let snappedTime = snapEngine.isActive ? snapEngine.snapTime(targetTime) : targetTime

        // Ensure minimum duration (at least 1 frame)
        let minDuration = max(frameDuration, 0.01)
        let maxTrimTime = clip.dstEnd - minDuration
        let clampedTime = max(clip.dstStart, min(snappedTime, maxTrimTime))

        guard abs(clampedTime - clip.dstStart) > 1e-9 else { return composition }

        let deltaTime = clampedTime - clip.dstStart
        let speed = clip.effectiveSpeed

        // Calculate source adjustment
        let srcDelta = deltaTime * speed

        // Clamp against asset bounds
        let assetDuration = AssetDurationRegistry.shared.duration(for: clip) ?? (clip.srcRange.start.seconds + clip.srcRange.duration.seconds)
        let proposedSrcStart = clip.srcRange.start.seconds + srcDelta
        let maxSrcStart = max(0, assetDuration - frameDuration)
        let clampedSrcStart = min(max(proposedSrcStart, 0), maxSrcStart)

        let proposedSrcDuration = clip.srcRange.duration.seconds - srcDelta
        var clampedSrcDuration = max(frameDuration, proposedSrcDuration)
        clampedSrcDuration = min(clampedSrcDuration, max(frameDuration, assetDuration - clampedSrcStart))

        guard clampedSrcDuration >= frameDuration else { return composition }

        // Apply changes
        clip.dstStart = clampedTime
        clip.srcRange.start = CMTime(seconds: clampedSrcStart, preferredTimescale: clip.srcRange.start.timescale)
        clip.srcRange.duration = CMTime(seconds: clampedSrcDuration, preferredTimescale: clip.srcRange.duration.timescale)

        if !rippleMode {
            // Already set dstStart above
        }

        clips[index] = clip

        var keyframeTracks = composition.keyframeTracks
        if let layerID = clip.transformRef {
            let originalStartTime = composition.clips[index].dstStart
            let newStartTime = rippleMode ? originalStartTime : clampedTime
            let originalEndTime = composition.clips[index].dstEnd
            let newEndTime = clip.dstEnd
            keyframeTracks = keyframesTrimLeading(tracks: keyframeTracks,
                                                  layerID: layerID,
                                                  oldStart: originalStartTime,
                                                  newStart: newStartTime)
            keyframeTracks = keyframesTrimTrailing(tracks: keyframeTracks,
                                                   layerID: layerID,
                                                   oldEnd: originalEndTime,
                                                   newEnd: newEndTime)
        }

        if rippleMode && deltaTime > 0 {
            let originalEnd = composition.clips[index].dstEnd
            for idx in clips.indices where idx != index {
                guard sameTrack(clips[idx], clip) else { continue }
                if clips[idx].dstStart >= originalEnd {
                    let newStart = max(0, clips[idx].dstStart - deltaTime)
                    if let layerID = clips[idx].transformRef {
                        keyframeTracks = shiftKeyframesAfter(tracks: keyframeTracks,
                                                             layerID: layerID,
                                                             threshold: clips[idx].dstStart,
                                                             delta: -deltaTime)
                    }
                    clips[idx].dstStart = newStart
                }
            }
        }

        var updatedComposition = composition.updating(clips: clips, keyframeTracks: keyframeTracks)
        if rippleMode && deltaTime > 0 {
            let maxEndTime = updatedComposition.clips
                .map { $0.dstEnd }
                .max() ?? 0
            updatedComposition.duration = maxEndTime
        }
        return updatedComposition
    }
}

struct AELayerSwitchOperation: AEEditOperation {
    let layerID: UUID
    let muted: Bool?
    let solo: Bool?
    let locked: Bool?
    let blendMode: BlendMode?
    let matteMode: TrackMatteMode?
    let matteSourceLayerID: UUID??
    let type: AEEditType = .layerSwitches

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard let index = composition.tracks.firstIndex(where: { $0.id == layerID }) else {
            return composition
        }

        var tracks = composition.tracks
        var track = tracks[index]
        var changed = false

        if let muted = muted, track.muted != muted {
            track.muted = muted
            changed = true
        }
        if let solo = solo, track.solo != solo {
            track.solo = solo
            changed = true
        }
        if let locked = locked, track.locked != locked {
            track.locked = locked
            changed = true
        }
        if let blendMode = blendMode, track.blendMode != blendMode {
            track.blendMode = blendMode
            changed = true
        }
        // Matte settings moved to Clip level, not Track

        guard changed else { return composition }

        tracks[index] = track
        var updatedComposition = composition
        updatedComposition.tracks = tracks
        return updatedComposition
    }
}


struct AEReorderLayersOperation: AEEditOperation {
    let movingLayerIDs: [UUID]
    let destinationIndex: Int
    let type: AEEditType = .reorderLayers

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard !movingLayerIDs.isEmpty else { return composition }

        var orderedTracks = composition.tracks.sorted { $0.stackIndex < $1.stackIndex }
        guard !orderedTracks.isEmpty else { return composition }
        let originalOrder = orderedTracks.map { $0.id }

        let tracksByID = Dictionary(uniqueKeysWithValues: orderedTracks.map { ($0.id, $0) })
        let expandedLayerIDs = expandSelectionWithMattePairs(movingLayerIDs, tracksByID: tracksByID, clips: composition.clips)
        guard !expandedLayerIDs.isEmpty else { return composition }

        let movingSet = Set(expandedLayerIDs)
        let movingTracks = orderedTracks.filter { movingSet.contains($0.id) }
        guard !movingTracks.isEmpty else { return composition }

        orderedTracks.removeAll { movingSet.contains($0.id) }

        let clampedDestination = max(0, min(destinationIndex, orderedTracks.count))
        orderedTracks.insert(contentsOf: movingTracks, at: clampedDestination)

        if originalOrder == orderedTracks.map({ $0.id }) {
            return composition
        }

        let indexMap = normalizeStackOrder(for: &orderedTracks)
        let updatedClips = updateClipTrackAssignments(clips: composition.clips,
                                                      indexMap: indexMap)

        var updatedComposition = composition
        updatedComposition.tracks = orderedTracks
        updatedComposition.clips = updatedClips
        return updatedComposition
    }
}

struct AETrimOutOperation: AEEditOperation {
    let clipID: UUID
    let targetTime: TimeInterval
    let rippleMode: Bool
    let type: AEEditType = .trimOut

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard let index = composition.clips.firstIndex(where: { $0.id == clipID }) else {
            throw AEEditError.clipNotFound
        }

        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        var clips = composition.clips
        var clip = clips[index]

        // Calculate new trim position
        let snappedTime = snapEngine.isActive ? snapEngine.snapTime(targetTime) : targetTime

        // Ensure minimum duration (at least 1 frame)
        let minDuration = max(frameDuration, 0.01)
        let minTrimTime = clip.dstStart + minDuration
        let maxTrimTime = clip.dstEnd
        let clampedTime = max(minTrimTime, min(snappedTime, maxTrimTime))

        guard abs(clampedTime - clip.dstEnd) > 1e-9 else { return composition }

        let deltaTime = clampedTime - clip.dstEnd
        let speed = clip.effectiveSpeed

        // Calculate new duration
        let newDstDuration = clampedTime - clip.dstStart
        let newSrcDuration = newDstDuration * speed

        // Clamp against asset bounds
        let assetDuration = AssetDurationRegistry.shared.duration(for: clip) ?? (clip.srcRange.start.seconds + clip.srcRange.duration.seconds)
        let currentSrcStart = clip.srcRange.start.seconds
        var clampedSrcDuration = max(frameDuration, newSrcDuration)
        clampedSrcDuration = min(clampedSrcDuration, max(frameDuration, assetDuration - currentSrcStart))
        guard clampedSrcDuration >= frameDuration else { return composition }

        // Apply changes (TrimOut doesn't change srcStart, only duration)
        clip.srcRange.duration = CMTime(seconds: clampedSrcDuration, preferredTimescale: clip.srcRange.duration.timescale)

        var keyframeTracks = composition.keyframeTracks
        if let layerID = clip.transformRef {
            let originalEndTime = composition.clips[index].dstEnd
            let newEndTime = clip.dstEnd
            keyframeTracks = keyframesTrimTrailing(tracks: keyframeTracks,
                                                   layerID: layerID,
                                                   oldEnd: originalEndTime,
                                                   newEnd: newEndTime)
        }

        if !rippleMode {
            clips[index] = clip
            return composition.updating(clips: clips, keyframeTracks: keyframeTracks)
        }

        let originalEnd = composition.clips[index].dstEnd
        clips[index] = clip

        if deltaTime > 0 {
            for idx in clips.indices where idx != index {
                guard sameTrack(clips[idx], clip) else { continue }
                if clips[idx].dstStart >= originalEnd {
                    let newStart = max(0, clips[idx].dstStart - deltaTime)
                    if let layerID = clips[idx].transformRef {
                        keyframeTracks = shiftKeyframesAfter(tracks: keyframeTracks,
                                                             layerID: layerID,
                                                             threshold: clips[idx].dstStart,
                                                             delta: -deltaTime)
                    }
                    clips[idx].dstStart = newStart
                }
            }
        }

        var updatedComposition = composition.updating(clips: clips, keyframeTracks: keyframeTracks)
        if deltaTime > 0 {
            let maxEndTime = updatedComposition.clips
                .map { $0.dstEnd }
                .max() ?? 0
            updatedComposition.duration = maxEndTime
        }
        return updatedComposition
    }
}

struct AEMoveOperation: AEEditOperation {
    let clipIDs: [UUID]
    let delta: TimeInterval
    let type: AEEditType = .move

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard !clipIDs.isEmpty else { return composition }

        var clips = composition.clips
        var keyframeTracks = composition.keyframeTracks
        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        guard frameDuration > 0 else { return composition }

        let movingSet = Set(clipIDs)

        // Build lookup for clips per layer (transformRef) using indices for quick neighbour checks.
        var indicesByLayer: [UUID: [Int]] = [:]
        for (index, clip) in clips.enumerated() {
            let layerID = clip.transformRef ?? clip.id
            indicesByLayer[layerID, default: []].append(index)
        }
        for key in indicesByLayer.keys {
            indicesByLayer[key]?.sort { clips[$0].dstStart < clips[$1].dstStart }
        }

        // Prepare allowed shift bounds (in frames) for the moving group.
        var maxForwardFrames = Int64.max
        var maxBackwardFrames = Int64.max
        var minStartFrame = Int64.max

        let compositionEndFrame = timebase.frameIndex(for: composition.duration, rounding: .ceil)

        for id in clipIDs {
            guard let index = clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = clips[index]
            let layerKey = clip.transformRef ?? clip.id
            guard var laneIndices = indicesByLayer[layerKey], !laneIndices.isEmpty else { continue }
            guard let lanePosition = laneIndices.firstIndex(of: index) else { continue }

            let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
            let clipEndFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)
            minStartFrame = min(minStartFrame, clipStartFrame)

            // Previous non-moving neighbour
            var previousSpace = clipStartFrame
            var previousIdx = lanePosition - 1
            while previousIdx >= 0 {
                let neighbourIndex = laneIndices[previousIdx]
                let neighbourClip = clips[neighbourIndex]
                if movingSet.contains(neighbourClip.id) {
                    previousIdx -= 1
                    continue
                }
                let neighbourEndFrame = timebase.frameIndex(for: neighbourClip.dstEnd, rounding: .ceil)
                previousSpace = max(0, clipStartFrame - neighbourEndFrame)
                break
            }
            maxBackwardFrames = min(maxBackwardFrames, previousSpace)

            // Next non-moving neighbour
            var nextSpace = compositionEndFrame - clipEndFrame
            var nextIdx = lanePosition + 1
            while nextIdx < laneIndices.count {
                let neighbourIndex = laneIndices[nextIdx]
                let neighbourClip = clips[neighbourIndex]
                if movingSet.contains(neighbourClip.id) {
                    nextIdx += 1
                    continue
                }
                let neighbourStartFrame = timebase.frameIndex(for: neighbourClip.dstStart, rounding: .floor)
                nextSpace = max(0, neighbourStartFrame - clipEndFrame)
                break
            }
            maxForwardFrames = min(maxForwardFrames, nextSpace)
        }

        // Allow smooth positioning without frame quantization
        var deltaTime = delta

        // Calculate max allowed movement in time units
        let maxForwardTime = Double(maxForwardFrames) * frameDuration
        let maxBackwardTime = Double(maxBackwardFrames) * frameDuration

        if deltaTime > 0 {
            deltaTime = min(deltaTime, maxForwardTime)
        } else if deltaTime < 0 {
            deltaTime = max(deltaTime, -maxBackwardTime)
        }

        guard abs(deltaTime) > 1e-9 else { return composition }
        guard minStartFrame != Int64.max else { return composition }

        // Only apply snapping if snap engine is active
        if snapEngine.isActive {
            let groupStartTime = timebase.time(forFrameIndex: minStartFrame)
            let proposedStart = groupStartTime + deltaTime
            let snappedStart = snapEngine.snapTime(proposedStart)
            deltaTime = snappedStart - groupStartTime

            // Re-clamp after snapping
            if deltaTime > 0 {
                deltaTime = min(deltaTime, maxForwardTime)
            } else if deltaTime < 0 {
                deltaTime = max(deltaTime, -maxBackwardTime)
            }
        }

        for id in clipIDs {
            guard let index = clips.firstIndex(where: { $0.id == id }) else { continue }
            var clip = clips[index]
            let oldStart = clip.dstStart
            let oldEnd = clip.dstEnd

            // Apply continuous time delta directly without frame quantization
            let newStart = max(0.0, clip.dstStart + deltaTime)
            clip.dstStart = newStart
            clips[index] = clip

            if let layerID = clip.transformRef {
                keyframeTracks = shiftKeyframesInRange(tracks: keyframeTracks,
                                                       layerID: layerID,
                                                       range: oldStart..<oldEnd,
                                                       delta: deltaTime)
            }
        }

        return composition.updating(clips: clips, keyframeTracks: keyframeTracks)
    }
}

struct AESlipOperation: AEEditOperation {
    let clipID: UUID
    let delta: TimeInterval
    let type: AEEditType = .slip

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard abs(delta) > 1e-6 else { return composition }

        var result = composition
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw AEEditError.clipNotFound
        }
        var clip = result.clips[index]
        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        guard frameDuration > 0 else { return composition }

        let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .nearest)
        let targetFrame = timebase.frameIndex(for: clip.dstStart + delta, rounding: .nearest)
        var frameDelta = targetFrame - clipStartFrame
        guard frameDelta != 0 else { return composition }

        let clipDuration = clip.srcRange.duration.seconds
        let assetDuration = AssetDurationRegistry.shared.duration(for: clip)
        let minStart = max(0, clip.metadata.originalSrcStart ?? 0)
        let maxStart = assetDuration.map { max(minStart, $0 - clipDuration) }

        let speed = clip.effectiveSpeed
        let sourceSecondsPerFrame = frameDuration * speed
        let maxBackwardSource = max(0, clip.srcRange.start.seconds - minStart)
        let maxForwardSource = maxStart.map { max(0, $0 - clip.srcRange.start.seconds) }

        let maxBackwardFrames = Int64(floor(maxBackwardSource / max(sourceSecondsPerFrame, 1e-9)))
        let maxForwardFrames = maxForwardSource.map { Int64(floor($0 / max(sourceSecondsPerFrame, 1e-9))) } ?? Int64.max

        if frameDelta < 0 {
            frameDelta = max(frameDelta, -maxBackwardFrames)
        } else {
            frameDelta = min(frameDelta, maxForwardFrames)
        }

        guard frameDelta != 0 else { return composition }

        let timelineDelta = Double(frameDelta) * frameDuration
        let sourceDelta = timelineDelta * speed
        let newStart = clip.srcRange.start.seconds + sourceDelta

        var clampedStart = max(newStart, minStart)
        if let maxStart, clampedStart > maxStart {
            clampedStart = maxStart
        }

        if abs(clampedStart - clip.srcRange.start.seconds) < frameDuration * 0.5 {
            return composition
        }

        let timescale = clip.srcRange.duration.timescale != 0 ? clip.srcRange.duration.timescale : 600
        clip.srcRange = CMTimeRange(start: CMTime(seconds: clampedStart, preferredTimescale: timescale),
                                    duration: clip.srcRange.duration)
        result.clips[index] = clip
        return result
    }
}

struct AESlideOperation: AEEditOperation {
    let clipID: UUID
    let delta: TimeInterval
    let type: AEEditType = .slide

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        guard abs(delta) > 1e-6 else { return composition }

        var clips = composition.clips
        guard let clipIndex = clips.firstIndex(where: { $0.id == clipID }) else {
            throw AEEditError.clipNotFound
        }

        var keyframeTracks = composition.keyframeTracks
        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        guard frameDuration > 0 else { return composition }

        var clip = clips[clipIndex]
        let layerID = clip.transformRef ?? clip.id

        if let track = composition.tracks.first(where: { $0.id == layerID }), track.locked {
            return composition
        }

        let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
        let clipEndFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)
        let clipFrameCount = max(clipEndFrame - clipStartFrame, 1)
        let compositionEndFrame = timebase.frameIndex(for: composition.duration, rounding: .ceil)

        var previousIndex: Int?
        var nextIndex: Int?
        for index in clips.indices {
            guard index != clipIndex else { continue }
            let candidate = clips[index]
            guard (candidate.transformRef ?? candidate.id) == layerID else { continue }
            if candidate.dstEnd <= clip.dstStart {
                if let current = previousIndex {
                    if clips[current].dstEnd < candidate.dstEnd {
                        previousIndex = index
                    }
                } else {
                    previousIndex = index
                }
            } else if candidate.dstStart >= clip.dstEnd {
                if let current = nextIndex {
                    if clips[current].dstStart > candidate.dstStart {
                        nextIndex = index
                    }
                } else {
                    nextIndex = index
                }
            }
        }

        var minStartFrame: Int64 = 0
        var maxStartFrame: Int64 = compositionEndFrame - clipFrameCount

        if let prevIdx = previousIndex {
            let prevClip = clips[prevIdx]
            let prevStartFrame = timebase.frameIndex(for: prevClip.dstStart, rounding: .floor)
            minStartFrame = max(minStartFrame, prevStartFrame + 1)
        }

        if let nextIdx = nextIndex {
            let nextClip = clips[nextIdx]
            let nextEndFrame = timebase.frameIndex(for: nextClip.dstEnd, rounding: .ceil)
            maxStartFrame = min(maxStartFrame, nextEndFrame - clipFrameCount - 1)
        }

        if maxStartFrame < minStartFrame {
            return composition
        }

        let desiredFrames = Int64((delta / frameDuration).rounded())
        var newStartFrame = clipStartFrame + desiredFrames
        if newStartFrame < minStartFrame {
            newStartFrame = minStartFrame
        }
        if newStartFrame > maxStartFrame {
            newStartFrame = maxStartFrame
        }

        if newStartFrame == clipStartFrame {
            return composition
        }

        let appliedDeltaFrames = newStartFrame - clipStartFrame
        let appliedDeltaTime = Double(appliedDeltaFrames) * frameDuration
        let newStartTime = timebase.time(forFrameIndex: newStartFrame)

        let originalStart = clip.dstStart
        let originalEnd = clip.dstEnd
        clip.dstStart = newStartTime
        clips[clipIndex] = clip

        if let layer = clip.transformRef {
            keyframeTracks = shiftKeyframesInRange(tracks: keyframeTracks,
                                                   layerID: layer,
                                                   range: originalStart..<originalEnd,
                                                   delta: appliedDeltaTime)
        }

        if let prevIdx = previousIndex {
            let prevClip = clips[prevIdx]
            let prevStartFrame = timebase.frameIndex(for: prevClip.dstStart, rounding: .floor)
            guard newStartFrame > prevStartFrame else { return composition }
            let trimmed = prevClip.trimmed(toFrameRange: prevStartFrame..<newStartFrame,
                                           preserveID: true,
                                           using: timebase)
            clips[prevIdx] = trimmed
            if let layer = trimmed.transformRef {
                keyframeTracks = keyframesTrimTrailing(tracks: keyframeTracks,
                                                       layerID: layer,
                                                       oldEnd: prevClip.dstEnd,
                                                       newEnd: trimmed.dstEnd)
            }
        }

        if let nextIdx = nextIndex {
            let nextClip = clips[nextIdx]
            let nextEndFrame = timebase.frameIndex(for: nextClip.dstEnd, rounding: .ceil)
            let newNextStartFrame = newStartFrame + clipFrameCount
            guard newNextStartFrame < nextEndFrame else { return composition }
            let trimmed = nextClip.trimmed(toFrameRange: newNextStartFrame..<nextEndFrame,
                                           preserveID: true,
                                           using: timebase)
            clips[nextIdx] = trimmed
            if let layer = trimmed.transformRef {
                keyframeTracks = keyframesTrimLeading(tracks: keyframeTracks,
                                                      layerID: layer,
                                                      oldStart: nextClip.dstStart,
                                                      newStart: trimmed.dstStart)
            }
        }

        var updated = composition.updating(clips: clips, keyframeTracks: keyframeTracks)
        let newDurationFrame = updated.clips
            .map { timebase.frameIndex(for: $0.dstEnd, rounding: .ceil) }
            .max() ?? 0
        updated.duration = timebase.time(forFrameIndex: newDurationFrame)
        return updated
    }
}

struct AESplitClipOperation: AEEditOperation {
    let time: TimeInterval
    let type: AEEditType = .split

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        let timebase = composition.frameTimebase
        let frameDuration = timebase.frameDuration.seconds
        guard frameDuration > 0 else { return composition }

        let target = snapEngine.snapTime(time)
        guard let index = composition.clips.firstIndex(where: { clip in
            clip.dstStart < target && target < clip.dstEnd && clip.duration > 0
        }) else { return composition }

        let clip = composition.clips[index]
        let minSlice = frameDuration
        guard clip.duration >= minSlice * 2 else { return composition }

        let constrainedTarget = min(max(target, clip.dstStart + minSlice), clip.dstEnd - minSlice)
        let startFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
        let endFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)
        let targetFrame = timebase.frameIndex(for: constrainedTarget, rounding: .nearest)
        guard targetFrame > startFrame && targetFrame < endFrame else { return composition }

        var leftClip = clip.trimmed(toFrameRange: startFrame..<targetFrame,
                                    preserveID: true,
                                    using: timebase)
        var rightClip = clip.trimmed(toFrameRange: targetFrame..<endFrame,
                                     preserveID: false,
                                     using: timebase)

        leftClip.name = clip.name
        rightClip.name = clip.name.replacingOccurrences(of: " (Split)", with: "") + " (Split)"

        let originalLayerID = clip.transformRef ?? clip.id
        var updatedTracks = composition.tracks
        var updatedKeyframes = composition.keyframeTracks
        var updatedClips = composition.clips
        updatedClips.remove(at: index)

        if let trackIndex = updatedTracks.firstIndex(where: { $0.id == originalLayerID }) {
            let originalTrack = updatedTracks[trackIndex]
            let newTrackID = UUID()

            let newTrack = Track(id: newTrackID,
                                 stackIndex: originalTrack.stackIndex + 1,
                                 kind: originalTrack.kind,
                                 name: originalTrack.name.replacingOccurrences(of: " (Split)", with: "") + " (Split)",
                                 muted: originalTrack.muted,
                                 solo: originalTrack.solo,
                                 locked: originalTrack.locked,
                                 color: originalTrack.color,
                                 blendMode: originalTrack.blendMode)

            updatedTracks = updatedTracks.map { track in
                if track.stackIndex > originalTrack.stackIndex {
                    var adjusted = track
                    adjusted.stackIndex += 1
                    return adjusted
                }
                return track
            }
            updatedTracks.append(newTrack)
            updatedTracks.sort { $0.stackIndex < $1.stackIndex }

            leftClip.transformRef = originalLayerID
            rightClip.transformRef = newTrackID

            var keyframeTracks: [TimelineKeyframeTrack] = updatedKeyframes.filter { $0.layerID != originalLayerID }
            let originalKeyframeTracks = updatedKeyframes.filter { $0.layerID == originalLayerID }
            for track in originalKeyframeTracks {
                let (leftKeys, rightKeys) = splitKeyframes(track.keyframes, at: constrainedTarget)
                if !leftKeys.isEmpty {
                    keyframeTracks.append(TimelineKeyframeTrack(id: track.id,
                                                               layerID: originalLayerID,
                                                               propertyPath: track.propertyPath,
                                                               keyframes: leftKeys))
                }
                if !rightKeys.isEmpty {
                    keyframeTracks.append(TimelineKeyframeTrack(layerID: newTrackID,
                                                               propertyPath: track.propertyPath,
                                                               keyframes: rightKeys))
                }
            }
            updatedKeyframes = keyframeTracks

            var normalizedTracks = updatedTracks
            let indexMap = normalizeStackOrder(for: &normalizedTracks)
            updatedTracks = normalizedTracks
            leftClip.videoTrackIndex = indexMap[originalLayerID]
            rightClip.videoTrackIndex = indexMap[newTrackID]

            updatedClips.insert(contentsOf: [leftClip, rightClip], at: index)

            var updatedComposition = composition.updating(clips: updatedClips,
                                                          tracks: updatedTracks,
                                                          keyframeTracks: updatedKeyframes)
            let maxEnd = updatedClips.map { $0.dstEnd }.max() ?? updatedComposition.duration
            updatedComposition.duration = max(updatedComposition.duration, maxEnd)
            return updatedComposition
        } else {
            leftClip.transformRef = clip.transformRef
            rightClip.transformRef = clip.transformRef
            updatedClips.insert(contentsOf: [leftClip, rightClip], at: index)

            var updatedComposition = composition.updating(clips: updatedClips, keyframeTracks: updatedKeyframes)
            let maxEnd = updatedClips.map { $0.dstEnd }.max() ?? updatedComposition.duration
            updatedComposition.duration = max(updatedComposition.duration, maxEnd)
            return updatedComposition
        }
    }

    private func splitKeyframes(_ keyframes: [TimelineKeyframe], at splitTime: TimeInterval) -> ([TimelineKeyframe], [TimelineKeyframe]) {
        guard !keyframes.isEmpty else {
            let defaultKey = TimelineKeyframe(time: splitTime, value: 100)
            return ([defaultKey], [defaultKey])
        }

        let sorted = keyframes.sorted { $0.time < $1.time }
        var left: [TimelineKeyframe] = []
        var right: [TimelineKeyframe] = []

        for key in sorted {
            if key.time < splitTime - keyframeEpsilon {
                left.append(key)
            } else if key.time > splitTime + keyframeEpsilon {
                right.append(key)
            } else {
                left.append(key)
                right.append(TimelineKeyframe(time: key.time, value: key.value))
            }
        }

        let splitValue: Float
        if let exact = sorted.last(where: { abs($0.time - splitTime) <= keyframeEpsilon }) {
            splitValue = exact.value
        } else if let last = left.last {
            splitValue = last.value
            left.append(TimelineKeyframe(time: splitTime, value: splitValue))
        } else if let first = right.first {
            splitValue = first.value
        } else {
            splitValue = 100
        }

        if right.isEmpty || abs((right.first?.time ?? splitTime) - splitTime) > keyframeEpsilon {
            right.insert(TimelineKeyframe(time: splitTime, value: splitValue), at: 0)
        }

        return (left, right)
    }
}

struct AEDeleteClipOperation: AEEditOperation {
    let time: TimeInterval
    let type: AEEditType = .lift

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        let timebase = composition.frameTimebase
        let targetTime = snapEngine.snapTime(time)
        let targetFrame = timebase.frameIndex(for: targetTime, rounding: .nearest)

        guard let index = composition.clips.firstIndex(where: { clip in
            let startFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
            let endFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)
            if startFrame >= endFrame { return false }
            if targetFrame == endFrame { return targetFrame - 1 >= startFrame }
            return targetFrame >= startFrame && targetFrame < endFrame
        }) else { return composition }
        var updated = composition.clips
        updated.remove(at: index)
        return composition.updating(clips: updated)
    }
}

enum AESnapSystem {
    static let shared = SnapEngine()
}

// MARK: - Range Operations

struct AELiftOperation: AEEditOperation {
    let range: TimelineEditRange
    let affectedLayerIDs: Set<UUID>?
    let type: AEEditType = .lift

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        let timebase = composition.frameTimebase
        let snappedStart = snapEngine.snapTime(range.start)
        let snappedEnd = snapEngine.snapTime(range.end)
        let orderedStart = min(snappedStart, snappedEnd)
        let orderedEnd = max(snappedStart, snappedEnd)

        let startFrame = timebase.frameIndex(for: orderedStart, rounding: .floor)
        let endFrame = timebase.frameIndex(for: orderedEnd, rounding: .ceil)
        guard endFrame > startFrame else { return composition }

        let relevantIDs = targetedLayerIDs(from: affectedLayerIDs)
        var updated: [Clip] = []

        for clip in composition.clips.sorted(by: { $0.dstStart < $1.dstStart }) {
            guard shouldAffect(clip: clip, layerIDs: relevantIDs) else {
                updated.append(clip)
                continue
            }

            let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
            let clipEndFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)

            if clipEndFrame <= startFrame || clipStartFrame >= endFrame {
                updated.append(clip)
                continue
            }

            if clipStartFrame < startFrame {
                let leftUpper = min(clipEndFrame, startFrame)
                if leftUpper > clipStartFrame {
                    let leftRange = clipStartFrame..<leftUpper
                    let left = clip.trimmed(toFrameRange: leftRange, preserveID: true, using: timebase)
                    updated.append(left)
                }
            }

            if clipEndFrame > endFrame {
                let rightLower = max(clipStartFrame, endFrame)
                if clipEndFrame > rightLower {
                    let rightRange = rightLower..<clipEndFrame
                    let right = clip.trimmed(toFrameRange: rightRange, preserveID: false, using: timebase)
                    updated.append(right)
                }
            }
        }

        return composition.updating(clips: updated)
    }
}

struct AEExtractOperation: AEEditOperation {
    let range: TimelineEditRange
    let affectedLayerIDs: Set<UUID>?
    let type: AEEditType = .extract

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        let timebase = composition.frameTimebase
        let snappedStart = snapEngine.snapTime(range.start)
        let snappedEnd = snapEngine.snapTime(range.end)
        let orderedStart = min(snappedStart, snappedEnd)
        let orderedEnd = max(snappedStart, snappedEnd)

        let startFrame = timebase.frameIndex(for: orderedStart, rounding: .floor)
        let endFrame = timebase.frameIndex(for: orderedEnd, rounding: .ceil)
        guard endFrame > startFrame else { return composition }

        let deltaFrames = endFrame - startFrame

        let relevantIDs = targetedLayerIDs(from: affectedLayerIDs)
        var updated: [Clip] = []

        for clip in composition.clips.sorted(by: { $0.dstStart < $1.dstStart }) {
            guard shouldAffect(clip: clip, layerIDs: relevantIDs) else {
                updated.append(clip)
                continue
            }

            let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
            let clipEndFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)

            if clipEndFrame <= startFrame {
                updated.append(clip)
            } else if clipStartFrame >= endFrame {
                var shifted = clip
                let newStartFrame = max(0, clipStartFrame - deltaFrames)
                shifted.dstStart = timebase.time(forFrameIndex: newStartFrame)
                updated.append(shifted)
            } else {
                if clipStartFrame < startFrame {
                    let leftUpper = min(clipEndFrame, startFrame)
                    if leftUpper > clipStartFrame {
                        let leftRange = clipStartFrame..<leftUpper
                        let left = clip.trimmed(toFrameRange: leftRange,
                                                preserveID: true,
                                                using: timebase)
                        updated.append(left)
                    }
                }

                if clipEndFrame > endFrame {
                    let rightLower = max(clipStartFrame, endFrame)
                    if clipEndFrame > rightLower {
                        var right = clip.trimmed(toFrameRange: rightLower..<clipEndFrame,
                                                 preserveID: false,
                                                 using: timebase)
                        let rightStartFrame = timebase.frameIndex(for: right.dstStart, rounding: .floor)
                        let adjustedFrame = max(0, rightStartFrame - deltaFrames)
                        right.dstStart = timebase.time(forFrameIndex: adjustedFrame)
                        updated.append(right)
                    }
                }
            }
        }

        var result = composition.updating(clips: updated)
        let newDurationFrame = result.clips
            .map { timebase.frameIndex(for: $0.dstEnd, rounding: .ceil) }
            .max() ?? 0
        result.duration = timebase.time(forFrameIndex: newDurationFrame)
        return result
    }
}

struct AEGapRemoveOperation: AEEditOperation {
    let range: TimelineEditRange
    let type: AEEditType = .rippleDelete

    func execute(on composition: Composition, snapEngine: SnapEngine) throws -> Composition {
        let timebase = composition.frameTimebase
        let snappedStart = snapEngine.snapTime(range.start)
        let snappedEnd = snapEngine.snapTime(range.end)
        let orderedStart = min(snappedStart, snappedEnd)
        let orderedEnd = max(snappedStart, snappedEnd)

        let startFrame = timebase.frameIndex(for: orderedStart, rounding: .floor)
        let endFrame = timebase.frameIndex(for: orderedEnd, rounding: .ceil)
        guard endFrame > startFrame else { return composition }

        let deltaFrames = endFrame - startFrame

        var updated: [Clip] = []
        for clip in composition.clips {
            let clipStartFrame = timebase.frameIndex(for: clip.dstStart, rounding: .floor)
            let clipEndFrame = timebase.frameIndex(for: clip.dstEnd, rounding: .ceil)

            if clipEndFrame <= startFrame {
                updated.append(clip)
            } else if clipStartFrame >= endFrame {
                var shifted = clip
                let newStartFrame = max(0, clipStartFrame - deltaFrames)
                shifted.dstStart = timebase.time(forFrameIndex: newStartFrame)
                updated.append(shifted)
            } else {
                // Guards: overlapping gap indicates invalid request, return original composition
                return composition
            }
        }

        var result = composition.updating(clips: updated)
        let newDurationFrame = result.clips
            .map { timebase.frameIndex(for: $0.dstEnd, rounding: .ceil) }
            .max() ?? 0
        result.duration = timebase.time(forFrameIndex: newDurationFrame)
        return result
    }
}

private func targetedLayerIDs(from ids: Set<UUID>?) -> Set<UUID>? {
    guard let ids, !ids.isEmpty else { return nil }
    return ids
}

private func shouldAffect(clip: Clip, layerIDs: Set<UUID>?) -> Bool {
    guard let layerIDs else { return true }
    guard let layerID = clip.transformRef else { return false }
    return layerIDs.contains(layerID)
}

private func sameTrack(_ lhs: Clip, _ rhs: Clip) -> Bool {
    if let lVideo = lhs.videoTrackIndex, let rVideo = rhs.videoTrackIndex {
        return lVideo == rVideo
    }
    if let lAudio = lhs.audioTrackIndex, let rAudio = rhs.audioTrackIndex {
        return lAudio == rAudio
    }
    return false
}

private func expandSelectionWithMattePairs(_ layerIDs: [UUID], tracksByID: [UUID: Track], clips: [Clip] = []) -> [UUID] {
    guard !layerIDs.isEmpty else { return [] }

    var expanded: Set<UUID> = Set(layerIDs)
    var didChange = true

    // Matte expansion now handled at clip level
    while didChange {
        didChange = false
        for clip in clips {
            guard clip.matteMode != .none, let matteSourceID = clip.matteSourceID else { continue }
            let clipLayerID = clip.transformRef ?? clip.id

            // Find the matte source clip's layer
            if let matteClip = clips.first(where: { $0.id == matteSourceID }) {
                let matteLayerID = matteClip.transformRef ?? matteClip.id

                if expanded.contains(clipLayerID), !expanded.contains(matteLayerID) {
                    expanded.insert(matteLayerID)
                    didChange = true
                }
                if expanded.contains(matteLayerID), !expanded.contains(clipLayerID) {
                    expanded.insert(clipLayerID)
                    didChange = true
                }
            }
        }
    }

    return expanded.sorted { lhs, rhs in
        guard let lhsTrack = tracksByID[lhs], let rhsTrack = tracksByID[rhs] else { return false }
        return lhsTrack.stackIndex < rhsTrack.stackIndex
    }
}

@discardableResult
private func normalizeStackOrder(for tracks: inout [Track]) -> [UUID: Int] {
    var map: [UUID: Int] = [:]
    for index in tracks.indices {
        tracks[index].stackIndex = index
        map[tracks[index].id] = index
    }
    return map
}

private func updateClipTrackAssignments(clips: [Clip], indexMap: [UUID: Int]) -> [Clip] {
    guard !clips.isEmpty else { return clips }
    var updated = clips
    for index in updated.indices {
        guard let layerID = updated[index].transformRef,
              let newStackIndex = indexMap[layerID] else { continue }
        updated[index].videoTrackIndex = newStackIndex
    }
    return updated
}

private let keyframeEpsilon: TimeInterval = 1e-6

private func keyframesTrimLeading(tracks: [TimelineKeyframeTrack],
                                  layerID: UUID,
                                  oldStart: TimeInterval,
                                  newStart: TimeInterval) -> [TimelineKeyframeTrack] {
    tracks.map { track in
        guard track.layerID == layerID else { return track }
        let sorted = track.keyframes.sorted { $0.time < $1.time }
        var removed: [TimelineKeyframe] = []
        var retained: [TimelineKeyframe] = []
        for key in sorted {
            if key.time < newStart - keyframeEpsilon {
                removed.append(key)
            } else {
                retained.append(key)
            }
        }

        if retained.isEmpty {
            if let last = removed.last {
                retained.insert(TimelineKeyframe(time: newStart, value: last.value), at: 0)
            }
        } else if abs(retained[0].time - newStart) > keyframeEpsilon {
            let value = removed.last?.value ?? retained[0].value
            retained.insert(TimelineKeyframe(time: newStart, value: value), at: 0)
        } else {
            retained[0].time = newStart
        }

        return TimelineKeyframeTrack(id: track.id,
                                     layerID: track.layerID,
                                     propertyPath: track.propertyPath,
                                     keyframes: retained.sorted { $0.time < $1.time })
    }
}

private func keyframesTrimTrailing(tracks: [TimelineKeyframeTrack],
                                   layerID: UUID,
                                   oldEnd: TimeInterval,
                                   newEnd: TimeInterval) -> [TimelineKeyframeTrack] {
    tracks.map { track in
        guard track.layerID == layerID else { return track }
        let sorted = track.keyframes.sorted { $0.time < $1.time }
        var retained: [TimelineKeyframe] = []
        for key in sorted {
            if key.time <= newEnd + keyframeEpsilon {
                retained.append(key)
            }
        }

        if retained.isEmpty, let last = sorted.last {
            retained = [TimelineKeyframe(time: newEnd, value: last.value)]
        } else if let last = retained.last, abs(last.time - newEnd) > keyframeEpsilon {
            let value = last.value
            retained.append(TimelineKeyframe(time: newEnd, value: value))
        } else if let last = retained.last, last.time > newEnd {
            retained[retained.count - 1] = TimelineKeyframe(id: last.id, time: newEnd, value: last.value)
        }

        return TimelineKeyframeTrack(id: track.id,
                                     layerID: track.layerID,
                                     propertyPath: track.propertyPath,
                                     keyframes: retained.sorted { $0.time < $1.time })
    }
}

private func shiftKeyframesInRange(tracks: [TimelineKeyframeTrack],
                                   layerID: UUID,
                                   range: Range<TimeInterval>,
                                   delta: TimeInterval) -> [TimelineKeyframeTrack] {
    guard abs(delta) > keyframeEpsilon else { return tracks }
    return tracks.map { track in
        guard track.layerID == layerID else { return track }
        let adjusted = track.keyframes.map { key -> TimelineKeyframe in
            if key.time >= range.lowerBound - keyframeEpsilon && key.time < range.upperBound + keyframeEpsilon {
                return TimelineKeyframe(id: key.id,
                                        time: max(0, key.time + delta),
                                        value: key.value)
            }
            return key
        }
        return TimelineKeyframeTrack(id: track.id,
                                     layerID: track.layerID,
                                     propertyPath: track.propertyPath,
                                     keyframes: adjusted.sorted { $0.time < $1.time })
    }
}

private func shiftKeyframesAfter(tracks: [TimelineKeyframeTrack],
                                 layerID: UUID,
                                 threshold: TimeInterval,
                                 delta: TimeInterval) -> [TimelineKeyframeTrack] {
    guard abs(delta) > keyframeEpsilon else { return tracks }
    return tracks.map { track in
        guard track.layerID == layerID else { return track }
        let adjusted = track.keyframes.map { key -> TimelineKeyframe in
            if key.time >= threshold - keyframeEpsilon {
                return TimelineKeyframe(id: key.id,
                                        time: max(0, key.time + delta),
                                        value: key.value)
            }
            return key
        }
        return TimelineKeyframeTrack(id: track.id,
                                     layerID: track.layerID,
                                     propertyPath: track.propertyPath,
                                     keyframes: adjusted.sorted { $0.time < $1.time })
    }
}
