import CoreMedia

struct TimeRemapKeyframe {
    let t: CMTime
    let speed: Double
}

protocol TimeRemapper {
    func mediaTime(for timelineTime: CMTime) -> CMTime
}

struct IdentityTimeRemapper: TimeRemapper {
    func mediaTime(for timelineTime: CMTime) -> CMTime {
        timelineTime
    }
}

struct CurveTimeRemapper: TimeRemapper {
    private let keys: [TimeRemapKeyframe]

    init(keys: [TimeRemapKeyframe]) {
        self.keys = keys
    }

    func mediaTime(for timelineTime: CMTime) -> CMTime {
        // Placeholder: real implementation will interpolate keyframes.
        guard let match = keys.last(where: { $0.t <= timelineTime }) else {
            return timelineTime
        }
        let speed = match.speed
        let delta = CMTimeSubtract(timelineTime, match.t)
        let scaled = CMTimeMultiplyByFloat64(delta, multiplier: speed)
        return CMTimeAdd(match.t, scaled)
    }
}
