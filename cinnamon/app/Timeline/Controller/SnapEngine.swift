import Foundation
import Combine
import CoreMedia

public struct SnapResult: Sendable {
    public let snappedTime: TimeInterval
    public let source: SnapSource?
}

public enum SnapSource: String, CaseIterable, Sendable {
    case playhead, markers, layerInOut, keyframes, workArea, grid
}

public struct SnapTolerance: Sendable {
    public var milliseconds: Double
    public init(milliseconds: Double = 10) {
        self.milliseconds = milliseconds
    }
}

public final class SnapEngine: ObservableObject {
    @Published public var enabledSources: Set<SnapSource> = [.playhead, .markers, .layerInOut]
    @Published public var tolerance: SnapTolerance = SnapTolerance(milliseconds: 10)
    @Published public var isActive: Bool = false // Disable snapping by default for smooth movement
    @Published public var quantizeToFrames: Bool = false // Disable frame quantization for smooth positioning

    private var frameTimebase = FrameTimebase(frameRate: 24)
    private var snapTargets: [SnapSource: [TimeInterval]] = [:]
    private var playheadTime: TimeInterval = 0

    public init() {}

    public func updateFrameRate(_ frameRate: Double) {
        frameTimebase = FrameTimebase(frameRate: frameRate)
    }

    public func updateComposition(_ composition: Composition) {
        frameTimebase = composition.frameTimebase
        var targets: [SnapSource: [TimeInterval]] = [:]

        let markerTimes = composition.markers.map { $0.time }.sorted()
        if !markerTimes.isEmpty {
            targets[.markers] = markerTimes
        }

        var layerInOutTimes: [TimeInterval] = []
        for clip in composition.clips {
            layerInOutTimes.append(clip.dstStart)
            layerInOutTimes.append(clip.dstEnd)
        }
        if !layerInOutTimes.isEmpty {
            targets[.layerInOut] = Array(Set(layerInOutTimes)).sorted()
        }

        if let workArea = composition.workArea {
            targets[.workArea] = [workArea.start.seconds, workArea.end.seconds]
        }

        let frameDuration = frameTimebase.frameDuration.seconds
        if frameDuration > 0 {
            let maxGridPoints = min(5000, Int((composition.duration / frameDuration).rounded(.down)))
            if maxGridPoints > 0 {
                let gridTimes = (0...maxGridPoints).map { frameTimebase.time(forFrameIndex: Int64($0)) }
                targets[.grid] = gridTimes
            }
        }

        targets[.keyframes] = [] // Keyframe data pending integration
        let keyframeTimes = composition.keyframeTracks.flatMap { track in
            track.keyframes.map { $0.time }
        }
        if !keyframeTimes.isEmpty {
            targets[.keyframes] = keyframeTimes.sorted()
        }

        snapTargets = targets
    }

    public func updatePlayhead(_ time: TimeInterval) {
        playheadTime = time
    }

    public func snapTime(_ targetTime: TimeInterval) -> TimeInterval {
        let baseTime = quantizeToFrames ? frameTimebase.quantize(targetTime, rounding: .nearest) : targetTime
        guard isActive else { return baseTime }

        let toleranceSeconds = tolerance.milliseconds / 1000.0
        var bestTime = baseTime
        var bestSource: SnapSource?
        var bestDelta = toleranceSeconds

        for source in enabledSources {
            switch source {
            case .playhead:
                let delta = abs(baseTime - playheadTime)
                if delta <= bestDelta {
                    bestDelta = delta
                    bestSource = .playhead
                    bestTime = playheadTime
                }
            default:
                guard let times = snapTargets[source] else { continue }
                for t in times {
                    let delta = abs(baseTime - t)
                    if delta <= bestDelta {
                        bestDelta = delta
                        bestSource = source
                        bestTime = t
                    }
                }
            }
        }

        if let bestSource, bestSource == .grid {
            // grid snapping not yet implemented; fallback to frame quantization
            return baseTime
        }

        return bestTime
    }
}
