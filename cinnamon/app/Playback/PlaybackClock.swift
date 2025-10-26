import Foundation
import QuartzCore
import AVFoundation

/// Authoritative playback clock that tracks timeline position using a monotonic
/// host timebase. Subsystems can request play/pause/seek transitions while
/// decoder- or audio-backed drivers may feed in corrective samples to eliminate
/// drift.
@MainActor
final class PlaybackClock {
    enum Source: String, Sendable {
        case transport
        case audio
        case video
        case external
    }

    struct State: Sendable {
        var time: TimeInterval
        var rate: Double
        var isPlaying: Bool
        var hostTime: CFTimeInterval
        var drift: TimeInterval
        var source: Source
    }

    struct Sample: Sendable {
        var time: TimeInterval
        var hostTime: CFTimeInterval
        var rate: Double
        var isPlaying: Bool
        var source: Source
    }

    static let shared = PlaybackClock()

    private let now: () -> CFTimeInterval
    private var baseTimelineTime: TimeInterval
    private var baseHostTime: CFTimeInterval
    private var state: State
    private var observers: [UUID: (State) -> Void] = [:]

    private convenience init() {
        self.init(nowProvider: CACurrentMediaTime)
    }

    private init(nowProvider: @escaping () -> CFTimeInterval) {
        now = nowProvider
        let host = nowProvider()
        baseTimelineTime = 0
        baseHostTime = host
        state = State(time: 0,
                      rate: 0,
                      isPlaying: false,
                      hostTime: host,
                      drift: 0,
                      source: .transport)
    }

    @discardableResult
    func addObserver(_ handler: @escaping (State) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(currentState())
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func currentState() -> State {
        var snapshot = state
        snapshot.time = currentTime()
        snapshot.hostTime = now()
        return snapshot
    }

    func currentTime(at hostTime: CFTimeInterval? = nil) -> TimeInterval {
        let host = hostTime ?? now()
        guard state.isPlaying, abs(state.rate) > .ulpOfOne else {
            return baseTimelineTime
        }
        return baseTimelineTime + (host - baseHostTime) * state.rate
    }

    func play(from time: TimeInterval,
              rate: Double,
              source: Source = .transport) {
        print("⚡ [DEBUG] PlaybackClock.play() called: time=\(time), rate=\(rate), source=\(source)")
        let host = now()
        baseTimelineTime = time
        baseHostTime = host
        updateState(time: time,
                    rate: rate,
                    isPlaying: true,
                    hostTime: host,
                    drift: 0,
                    source: source)
        print("⚡ [DEBUG] PlaybackClock.play() completed: isPlaying=\(state.isPlaying), rate=\(state.rate)")
    }

    func pause(at time: TimeInterval? = nil,
               source: Source = .transport) {
        let host = now()
        let resolvedTime = time ?? currentTime(at: host)
        print("🛑 [DEBUG] PlaybackClock.pause() called: time=\(resolvedTime), source=\(source)")
        baseTimelineTime = resolvedTime
        baseHostTime = host
        updateState(time: resolvedTime,
                    rate: 0,
                    isPlaying: false,
                    hostTime: host,
                    drift: state.drift,
                    source: source)
        print("🛑 [DEBUG] PlaybackClock.pause() completed: isPlaying=\(state.isPlaying), rate=\(state.rate)")
    }

    func seek(to time: TimeInterval,
              source: Source = .transport) {
        let host = now()
        print("🎯 [PlaybackClock] seek() CALLED: time=\(String(format: "%.3f", time))s, source=\(source)")
        print("   BEFORE: baseTimelineTime=\(String(format: "%.3f", baseTimelineTime))s")
        baseTimelineTime = time
        baseHostTime = host
        updateState(time: time,
                    rate: state.rate,
                    isPlaying: state.isPlaying && abs(state.rate) > .ulpOfOne,
                    hostTime: host,
                    drift: 0,
                    source: source)
        print("   AFTER: baseTimelineTime=\(String(format: "%.3f", baseTimelineTime))s, currentTime()=\(String(format: "%.3f", currentTime()))s")
    }

    func align(to time: TimeInterval,
               hostTime: CFTimeInterval? = nil,
               source: Source = .transport) {
        let host = hostTime ?? now()
        baseTimelineTime = time
        baseHostTime = host
        updateState(time: time,
                    rate: state.rate,
                    isPlaying: state.isPlaying,
                    hostTime: host,
                    drift: 0,
                    source: source)
    }

    func ingest(sample: Sample) {
        guard sample.isPlaying else {
            pause(at: sample.time, source: sample.source)
            return
        }

        let expected = currentTime(at: sample.hostTime)
        let drift = sample.time - expected
        baseTimelineTime = sample.time
        baseHostTime = sample.hostTime

        let newRate = abs(sample.rate) > .ulpOfOne ? sample.rate : state.rate
        updateState(time: sample.time,
                    rate: newRate,
                    isPlaying: true,
                    hostTime: sample.hostTime,
                    drift: drift,
                    source: sample.source)
    }

    func reset() {
        let host = now()
        baseTimelineTime = 0
        baseHostTime = host
        state = State(time: 0,
                      rate: 0,
                      isPlaying: false,
                      hostTime: host,
                      drift: 0,
                      source: .transport)
        notifyObservers()
    }

    private func updateState(time: TimeInterval,
                             rate: Double,
                             isPlaying: Bool,
                             hostTime: CFTimeInterval,
                             drift: TimeInterval,
                             source: Source) {
        var updated = state
        updated.time = max(0, time)
        updated.rate = rate
        updated.isPlaying = isPlaying
        updated.hostTime = hostTime
        updated.drift = drift
        updated.source = source

        guard shouldNotify(newState: updated) else { return }
        state = updated
        notifyObservers()
    }

    private func shouldNotify(newState: State) -> Bool {
        let epsilon = 1e-6
        if abs(newState.time - state.time) > epsilon { return true }
        if abs(newState.rate - state.rate) > epsilon { return true }
        if newState.isPlaying != state.isPlaying { return true }
        if abs(newState.hostTime - state.hostTime) > epsilon { return true }
        if abs(newState.drift - state.drift) > epsilon { return true }
        if newState.source != state.source { return true }
        return false
    }

    private func notifyObservers() {
        let snapshot = currentState()
        for handler in observers.values {
            handler(snapshot)
        }
    }
}

extension PlaybackClock.Sample {
    init(time: TimeInterval,
         hostTime: CFTimeInterval,
         rate: Double,
         source: PlaybackClock.Source) {
        self.time = time
        self.hostTime = hostTime
        self.rate = rate
        self.isPlaying = abs(rate) > .ulpOfOne
        self.source = source
    }
}

extension PlaybackClock.State {
    /// Converts the state's host time into an `AVAudioTime` for scheduling.
    func makeAudioTime(offsetSeconds: TimeInterval = 0) -> AVAudioTime {
        let seconds = hostTime + offsetSeconds
        let hostTicks = AVAudioTime.hostTime(forSeconds: seconds)
        return AVAudioTime(hostTime: hostTicks)
    }
}

extension PlaybackClock {
    static func makeTestingClock(now: @escaping () -> CFTimeInterval) -> PlaybackClock {
        PlaybackClock(nowProvider: now)
    }
}
