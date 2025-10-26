import Foundation
import AVFoundation

public struct TimelineValidationResult: Sendable {
    public var errors: [String]
    public var warnings: [String]
    public var gaps: [CMTimeRange]
    public var overlaps: [UUID: [UUID]]
    public var isFrameAligned: Bool

    public static let empty = TimelineValidationResult(errors: [], warnings: [], gaps: [], overlaps: [:], isFrameAligned: true)
}

public enum TimelineValidator {
    public static func validate(_ composition: Composition) -> TimelineValidationResult {
        var errors: [String] = []
        var warnings: [String] = []
        var gaps: [CMTimeRange] = []
        var overlaps: [UUID: [UUID]] = [:]

        let frameDuration = composition.frameRate > 0 ? 1.0 / composition.frameRate : 0
        var isFrameAligned = true

        let groupedByTrack = Dictionary(grouping: composition.clips) { clip -> Int in
            clip.videoTrackIndex ?? clip.audioTrackIndex ?? -1
        }

        for (trackIndex, clips) in groupedByTrack {
            let sorted = clips.sorted { $0.dstStart < $1.dstStart }
            var lastEnd: TimeInterval? = nil
            for clip in sorted {
                if frameDuration > 0 {
                    let alignedStart = (clip.dstStart / frameDuration).rounded() * frameDuration
                    let alignedEnd = (clip.dstEnd / frameDuration).rounded() * frameDuration
                    if abs(alignedStart - clip.dstStart) > 1e-6 || abs(alignedEnd - clip.dstEnd) > 1e-6 {
                        isFrameAligned = false
                    }
                }

                if let previousEnd = lastEnd {
                    if clip.dstStart < previousEnd - 1e-9 {
                        warnings.append("Track #\(trackIndex) clip overlap detected between \(clip.id)")
                        overlaps[clip.id, default: []].append(sorted.first { $0.dstEnd == previousEnd }?.id ?? UUID())
                    } else if clip.dstStart > previousEnd {
                        let gapRange = CMTimeRange(start: CMTime(seconds: previousEnd, preferredTimescale: 600),
                                                   end: CMTime(seconds: clip.dstStart, preferredTimescale: 600))
                        gaps.append(gapRange)
                    }
                }
                lastEnd = clip.dstEnd
            }
        }

        // Validate source ranges
        for clip in composition.clips {
            if clip.srcRange.duration <= .zero {
                errors.append("Clip \(clip.id) has invalid source duration")
            }
            if clip.dstEnd > composition.duration + 1e-6 {
                warnings.append("Clip \(clip.id) extends beyond composition duration")
            }
        }

        return TimelineValidationResult(errors: errors,
                                        warnings: warnings,
                                        gaps: gaps,
                                        overlaps: overlaps,
                                        isFrameAligned: isFrameAligned)
    }
}
