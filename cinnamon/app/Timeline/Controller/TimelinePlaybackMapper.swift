import Foundation

public struct TimelineSegment: Sendable, Identifiable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let clip: Clip?
    public let layerID: UUID
    public let isGap: Bool
    public let blendMode: BlendMode
    public let opacity: Float
    public let matteMode: TrackMatteMode
    public let matteLayerID: UUID?

    public init(id: UUID = UUID(),
                start: TimeInterval,
                end: TimeInterval,
                clip: Clip?,
                layerID: UUID,
                blendMode: BlendMode = .normal,
                opacity: Float = 1.0,
                matteMode: TrackMatteMode = .none,
                matteLayerID: UUID? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.clip = clip
        self.layerID = layerID
        self.isGap = (clip == nil)
        self.blendMode = blendMode
        self.opacity = opacity
        self.matteMode = matteMode
        self.matteLayerID = matteLayerID
    }

    public var duration: TimeInterval {
        end - start
    }

    public func contains(time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

public struct TimelinePlaybackData: Sendable {
    public let byLayer: [UUID: [TimelineSegment]]
    public let timeline: [TimelineSegment]
    public let compositeTimeline: [TimelineCompositeSlice]

    /// Find the segment containing the given time
    public func segmentAt(time: TimeInterval) -> TimelineSegment? {
        timeline.first { $0.contains(time: time) }
    }

    /// Check if time is in a gap
    public func isInGap(at time: TimeInterval) -> Bool {
        segmentAt(time: time)?.isGap ?? true
    }

    /// Get next valid segment after a gap
    public func nextValidSegment(after time: TimeInterval) -> TimelineSegment? {
        timeline.first { $0.start >= time && !$0.isGap }
    }
}

public struct TimelineMatteAttachment: Sendable {
    public let clip: Clip
    public let mode: TrackMatteMode
}

public struct TimelineCompositeSlice: Sendable, Identifiable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval
    public let orderedSegments: [TimelineSegment]
    public let primary: TimelineSegment?
    public let mattes: [UUID: TimelineMatteAttachment]

    public init(id: UUID = UUID(),
                start: TimeInterval,
                end: TimeInterval,
                orderedSegments: [TimelineSegment],
                primary: TimelineSegment?,
                mattes: [UUID: TimelineMatteAttachment]) {
        self.id = id
        self.start = start
        self.end = end
        self.orderedSegments = orderedSegments
        self.primary = primary
        self.mattes = mattes
    }

    public var duration: TimeInterval { end - start }

    func merged(with next: TimelineCompositeSlice) -> TimelineCompositeSlice {
        TimelineCompositeSlice(id: id,
                               start: start,
                               end: next.end,
                               orderedSegments: orderedSegments,
                               primary: primary,
                               mattes: mattes)
    }

    func isEquivalent(to other: TimelineCompositeSlice, tolerance: TimeInterval) -> Bool {
        guard orderedSegments.count == other.orderedSegments.count else { return false }
        for (lhs, rhs) in zip(orderedSegments, other.orderedSegments) {
            guard lhs.clip?.id == rhs.clip?.id,
                  lhs.layerID == rhs.layerID,
                  lhs.blendMode == rhs.blendMode,
                  abs(lhs.opacity - rhs.opacity) <= 1e-3 else {
                return false
            }
        }

        switch (primary?.clip?.id, other.primary?.clip?.id) {
        case let (lhs?, rhs?):
            guard lhs == rhs else { return false }
        case (nil, nil):
            break
        default:
            return false
        }

        guard mattes.count == other.mattes.count else { return false }
        for (key, lhsMatte) in mattes {
            guard let rhsMatte = other.mattes[key],
                  lhsMatte.clip.id == rhsMatte.clip.id,
                  lhsMatte.mode == rhsMatte.mode else {
                return false
            }
        }

        return abs(end - other.end) <= tolerance
    }
}

public enum TimelinePlaybackMapper {
    public static func segments(for composition: Composition) -> TimelinePlaybackData {
        let frameDuration = composition.frameRate > 0 ? 1.0 / composition.frameRate : 1.0 / 24.0
        let epsilon = max(frameDuration * 0.5, 1e-6)
        let debugEnabled = ProcessInfo.processInfo.environment["CIN_TIMELINE_DEBUG"] == "1"

        var trackInfo: [UUID: Track] = [:]
        var stackIndexForLayer: [UUID: Int] = [:]
        for track in composition.tracks {
            trackInfo[track.id] = track
            stackIndexForLayer[track.id] = track.stackIndex
        }

        var opacityTracks: [UUID: TimelineKeyframeTrack] = [:]
        for keyTrack in composition.keyframeTracks where keyTrack.propertyPath == "transform.opacity" {
            opacityTracks[keyTrack.layerID] = keyTrack
        }

        let sortedClips = composition.clips
            .filter { $0.enabled }
            .sorted {
                if abs($0.dstStart - $1.dstStart) > 1e-6 {
                    return $0.dstStart < $1.dstStart
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var byLayer: [UUID: [TimelineSegment]] = [:]
        for clip in sortedClips {
            let layerID = clip.transformRef ?? clip.id
            let blendMode = trackInfo[layerID]?.blendMode ?? .normal
            let opacity = opacityValue(for: clip, layerID: layerID, at: clip.dstStart)
            let segment = TimelineSegment(start: clip.dstStart,
                                          end: clip.dstEnd,
                                          clip: clip,
                                          layerID: layerID,
                                          blendMode: blendMode,
                                          opacity: opacity,
                                          matteMode: clip.matteMode,
                                          matteLayerID: clip.matteSourceID)
            byLayer[layerID, default: []].append(segment)
        }
        for key in byLayer.keys {
            byLayer[key]?.sort { $0.start < $1.start }
        }

        var breakpoints: Set<TimeInterval> = [0, composition.duration]
        for clip in sortedClips {
            breakpoints.insert(max(0, clip.dstStart))
            breakpoints.insert(max(0, clip.dstEnd))
        }
        let points = breakpoints.sorted()

        var timeline: [TimelineSegment] = []
        var compositeSlices: [TimelineCompositeSlice] = []
        let gapWarningThreshold = frameDuration * 3.0

        func clampOpacity(_ value: Float) -> Float {
            let normalized = value / 100.0
            return min(max(normalized, 0.0), 1.0)
        }

        func opacityValue(for clip: Clip, layerID: UUID, at time: TimeInterval) -> Float {
            let transformOpacity = max(0, min(clip.transform.opacity, 1))
            guard let track = opacityTracks[layerID], !track.keyframes.isEmpty else {
                return transformOpacity
            }
            let keyframes = track.keyframes.sorted { $0.time < $1.time }
            guard let first = keyframes.first else { return transformOpacity }
            if time <= first.time {
                return transformOpacity * clampOpacity(first.value)
            }
            if let last = keyframes.last, time >= last.time {
                return transformOpacity * clampOpacity(last.value)
            }
            for index in 0..<(keyframes.count - 1) {
                let lhs = keyframes[index]
                let rhs = keyframes[index + 1]
                if time >= lhs.time && time <= rhs.time {
                    let t = (time - lhs.time) / max(rhs.time - lhs.time, 1e-6)
                    let value = lhs.value + Float(t) * (rhs.value - lhs.value)
                    return transformOpacity * clampOpacity(value)
                }
            }
            return transformOpacity * clampOpacity(first.value)
        }

        func activeSegments(start: TimeInterval, end: TimeInterval) -> [TimelineSegment] {
            guard end - start > epsilon else { return [] }
            var result: [TimelineSegment] = []
            for clip in sortedClips {
                if clip.dstStart >= end - epsilon { break }
                if clip.dstEnd <= start + epsilon { continue }
                let layerID = clip.transformRef ?? clip.id
                let blendMode = trackInfo[layerID]?.blendMode ?? .normal
                let opacity = opacityValue(for: clip, layerID: layerID, at: start)
                result.append(TimelineSegment(start: start,
                                              end: end,
                                              clip: clip,
                                              layerID: layerID,
                                              blendMode: blendMode,
                                              opacity: opacity,
                                              matteMode: clip.matteMode,
                                              matteLayerID: clip.matteSourceID))
            }
            return result
        }

        func orderedSegments(_ segments: [TimelineSegment]) -> [TimelineSegment] {
            segments.sorted { lhs, rhs in
                guard let lhsClip = lhs.clip else { return false }
                guard let rhsClip = rhs.clip else { return true }
                let lhsZ = lhsClip.transform.zIndex
                let rhsZ = rhsClip.transform.zIndex
                if lhsZ != rhsZ { return lhsZ > rhsZ }
                let lhsStack = stackIndexForLayer[lhs.layerID] ?? 0
                let rhsStack = stackIndexForLayer[rhs.layerID] ?? 0
                if lhsStack != rhsStack { return lhsStack > rhsStack }
                let lhsStart = lhsClip.dstStart
                let rhsStart = rhsClip.dstStart
                if abs(lhsStart - rhsStart) > epsilon { return lhsStart < rhsStart }
                return lhsClip.id.uuidString < rhsClip.id.uuidString
            }
        }

        func segmentAbove(_ segment: TimelineSegment, in segments: [TimelineSegment]) -> TimelineSegment? {
            guard let index = segments.firstIndex(where: { $0.clip?.id == segment.clip?.id }) else { return nil }
            guard index > 0 else { return nil }
            return segments[index - 1]
        }

        func resolveMatteAssignments(for segments: [TimelineSegment]) -> ([TimelineSegment], [UUID: TimelineMatteAttachment]) {
            var ordered = orderedSegments(segments)
            var matteAssignments: [UUID: TimelineMatteAttachment] = [:]
            var matteClipIDs = Set<UUID>()

            for segment in ordered {
                guard let clip = segment.clip,
                      clip.matteMode != .none,
                      matteAssignments[clip.id] == nil else { continue }

                var candidate: TimelineSegment?

                if let matteID = clip.matteSourceID {
                    candidate = ordered.first { $0.clip?.id == matteID }
                } else if clip.useLayerAbove {
                    candidate = segmentAbove(segment, in: ordered)
                }

                guard let matteSegment = candidate,
                      let matteClip = matteSegment.clip,
                      matteClip.id != clip.id,
                      !matteClipIDs.contains(matteClip.id) else {
                    continue
                }

                if matteClip.matteSourceID == clip.id {
                    continue
                }

                if matteClip.useLayerAbove,
                   let above = segmentAbove(matteSegment, in: ordered),
                   above.clip?.id == clip.id {
                    continue
                }

                matteAssignments[clip.id] = TimelineMatteAttachment(clip: matteClip, mode: clip.matteMode)
                matteClipIDs.insert(matteClip.id)
            }

            var drawSegments: [TimelineSegment] = []
            for segment in ordered {
                guard let clip = segment.clip else { continue }
                guard !matteClipIDs.contains(clip.id) else { continue }
                guard !clip.hideAsRender else { continue }
                let attachment = matteAssignments[clip.id]
                drawSegments.append(TimelineSegment(start: segment.start,
                                                    end: segment.end,
                                                    clip: clip,
                                                    layerID: segment.layerID,
                                                    blendMode: segment.blendMode,
                                                    opacity: segment.opacity,
                                                    matteMode: attachment?.mode ?? .none,
                                                    matteLayerID: attachment?.clip.id))
            }

            return (drawSegments, matteAssignments)
        }

        func appendTimelineSegment(start: TimeInterval, end: TimeInterval, primary: TimelineSegment?, into timeline: inout [TimelineSegment]) {
            guard end - start > epsilon else { return }
            let segment: TimelineSegment
            if let primary {
                segment = TimelineSegment(start: start,
                                          end: end,
                                          clip: primary.clip,
                                          layerID: primary.layerID,
                                          blendMode: primary.blendMode,
                                          opacity: primary.opacity,
                                          matteMode: primary.matteMode,
                                          matteLayerID: primary.matteLayerID)
            } else {
                segment = TimelineSegment(start: start,
                                          end: end,
                                          clip: nil,
                                          layerID: UUID(),
                                          blendMode: .normal,
                                          opacity: 0.0,
                                          matteMode: .none,
                                          matteLayerID: nil)
            }

            if let last = timeline.last {
                let sameClip = last.clip?.id == segment.clip?.id
                let bothGaps = last.clip == nil && segment.clip == nil
                if sameClip && abs(last.opacity - segment.opacity) <= 1e-3 {
                    timeline[timeline.count - 1] = TimelineSegment(id: last.id,
                                                                   start: last.start,
                                                                   end: end,
                                                                   clip: last.clip,
                                                                   layerID: last.layerID,
                                                                   blendMode: last.blendMode,
                                                                   opacity: segment.opacity,
                                                                   matteMode: segment.matteMode,
                                                                   matteLayerID: segment.matteLayerID)
                    return
                }
                if bothGaps {
                    timeline[timeline.count - 1] = TimelineSegment(id: last.id,
                                                                   start: last.start,
                                                                   end: end,
                                                                   clip: nil,
                                                                   layerID: last.layerID,
                                                                   blendMode: .normal,
                                                                   opacity: 0.0,
                                                                   matteMode: .none,
                                                                   matteLayerID: nil)
                    return
                }
            }

            timeline.append(segment)
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if end - start <= epsilon { continue }

            let sliceSegments = activeSegments(start: start, end: end)
            let (drawSegments, matteAssignments) = resolveMatteAssignments(for: sliceSegments)
            let primary = drawSegments.first

            appendTimelineSegment(start: start, end: end, primary: primary, into: &timeline)

            if drawSegments.isEmpty, debugEnabled, end - start > gapWarningThreshold {
                print("[MAP] gap-warning size=\(end - start)")
            }

            let slice = TimelineCompositeSlice(start: start,
                                               end: end,
                                               orderedSegments: drawSegments,
                                               primary: primary,
                                               mattes: matteAssignments)
            if let last = compositeSlices.last, last.isEquivalent(to: slice, tolerance: epsilon) {
                compositeSlices[compositeSlices.count - 1] = last.merged(with: slice)
            } else {
                compositeSlices.append(slice)
            }
        }

        if timeline.isEmpty, let lastPoint = points.last, lastPoint > epsilon {
            let gap = TimelineSegment(start: 0,
                                      end: lastPoint,
                                      clip: nil,
                                      layerID: UUID(),
                                      blendMode: .normal,
                                      opacity: 0.0,
                                      matteMode: .none,
                                      matteLayerID: nil)
            timeline.append(gap)
        }

        return TimelinePlaybackData(byLayer: byLayer,
                                    timeline: timeline,
                                    compositeTimeline: compositeSlices)
    }
}
