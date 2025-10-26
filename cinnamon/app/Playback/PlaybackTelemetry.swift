import Foundation

/// Lightweight telemetry hook that logs clock drift when enabled via the
/// `CIN_PLAYBACK_TELEMETRY` environment flag.
@MainActor
final class PlaybackTelemetry {
    static let shared = PlaybackTelemetry()

    private let isEnabled: Bool
    private var token: UUID?
    private var driftSamples: [PlaybackClock.Source: [Double]] = [:]
    private let maxSamples = 120
    private let alertThreshold: TimeInterval = 0.003 // 3ms

    private init() {
        isEnabled = ProcessInfo.processInfo.environment["CIN_PLAYBACK_TELEMETRY"] == "1"
        guard isEnabled else { return }

        token = PlaybackClock.shared.addObserver { [weak self] state in
            self?.handle(state: state)
        }
    }

    private func handle(state: PlaybackClock.State) {
        guard state.source != .transport else { return }
        var samples = driftSamples[state.source, default: []]
        samples.append(state.drift)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        driftSamples[state.source] = samples

        let driftMS = state.drift * 1_000
        if abs(state.drift) >= alertThreshold {
            let message = String(format: "[Telemetry] ⚠️ drift=%+.2fms source=%@ time=%.3f rate=%.3f",
                                  driftMS,
                                  state.source.rawValue,
                                  state.time,
                                  state.rate)
            print(message)
        } else if samples.count == maxSamples {
            let mean = samples.reduce(0, +) / Double(samples.count)
            let stdev = sqrt(samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count))
            let summary = String(format: "[Telemetry] drift avg=%+.3fms σ=%.3fms source=%@",
                                 mean * 1_000,
                                 stdev * 1_000,
                                 state.source.rawValue)
            print(summary)
            driftSamples[state.source] = []
        }
    }
}
