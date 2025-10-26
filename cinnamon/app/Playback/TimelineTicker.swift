import Foundation
import QuartzCore
import CoreMedia

/// Drives the timeline using a single monotonic clock. The ticker runs on the
/// main queue so UI updates remain synchronized with playback.
@MainActor
final class TimelineTicker {
    private var timer: DispatchSourceTimer?
    private var handler: ((TimeInterval) -> Void)?
    private var isRunning = false
    private var baseTimelineTime: TimeInterval = 0
    private var baseHostTime: CFTimeInterval = 0
    private var rate: Double = 0
    private var lastEmittedTime: TimeInterval = 0
    private var frameCount: Int = 0  // FRAME-ACCURATE: Count ticks, not measure time

    private var frameTimebase: FrameTimebase = FrameTimebase(frameRate: 60.0)

    private var tickInterval: TimeInterval {
        // Ticker runs at frame-exact intervals using rational timebase
        return frameTimebase.frameDuration.seconds
    }

    func setFrameTimebase(_ timebase: FrameTimebase) {
        frameTimebase = timebase
        // Recreate timer with new framerate if currently running
        if isRunning {
            createTimer()
        }
    }

    func setCompositionFrameRate(_ frameRate: Double) {
        // DISPLAY-SYNC: Ticker always runs at display refresh rate (60Hz)
        // Composition framerate is only used for export, not preview playback
        // This eliminates micro-jitter from composition/display rate mismatch
        frameTimebase = FrameTimebase(frameRate: 60.0)
        let frameDur = frameTimebase.frameDuration.seconds
        print("[TimelineTicker] ✅ Display-Sync enabled @ 60Hz")
        print("  tickInterval: \(String(format: "%.4f", frameDur))s (\(String(format: "%.1f", 1000*frameDur))ms)")
        print("  Composition framerate: \(frameRate)fps (export only, not used for preview)")
        print("  Frame selection uses video native PTS (NEAREST-PREVIOUS)")
        // Recreate timer with new framerate if currently running
        if isRunning {
            createTimer()
        }
    }

    func start(from time: TimeInterval,
               rate: Double,
               handler: @escaping (TimeInterval) -> Void) {
        stop()
        self.handler = handler
        baseTimelineTime = time
        baseHostTime = CACurrentMediaTime()
        self.rate = rate
        lastEmittedTime = time
        frameCount = 0  // FRAME-ACCURATE: Reset frame counter

        // Ticker is the master, PlaybackClock follows
        PlaybackClock.shared.play(from: time, rate: rate, source: .transport)

        isRunning = abs(rate) > .ulpOfOne
        if isRunning {
            createTimer()
        }
        handler(time)
    }

    func updateRate(_ newRate: Double) {
        guard handler != nil else { return }
        let nowTime = currentTimelineTime()
        rate = newRate
        baseTimelineTime = nowTime
        baseHostTime = CACurrentMediaTime()
        frameCount = 0  // FRAME-ACCURATE: Reset frame counter on rate change

        // Update PlaybackClock to follow ticker
        if abs(newRate) > .ulpOfOne {
            PlaybackClock.shared.play(from: nowTime, rate: newRate, source: .transport)
        } else {
            PlaybackClock.shared.pause(at: nowTime, source: .transport)
        }

        let shouldRun = abs(newRate) > .ulpOfOne
        switch (isRunning, shouldRun) {
        case (true, true):
            break
        case (false, true):
            createTimer()
        case (true, false):
            timer?.cancel()
            timer = nil
        case (false, false):
            break
        }
        isRunning = shouldRun
    }

    func seek(to time: TimeInterval) {
        baseTimelineTime = time
        baseHostTime = CACurrentMediaTime()
        lastEmittedTime = time
        frameCount = 0  // FRAME-ACCURATE: Reset frame counter on seek
        // Update PlaybackClock position
        PlaybackClock.shared.seek(to: time, source: .transport)
        handler?(time)
    }

    func resync(to time: TimeInterval) {
        guard isRunning else { return }
        baseTimelineTime = time
        baseHostTime = CACurrentMediaTime()
        lastEmittedTime = time
        frameCount = 0
        PlaybackClock.shared.seek(to: time, source: .transport)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    private func createTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(),
                       repeating: tickInterval,
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        guard isRunning, let handler else { return }

        // FRAME-ACCURATE: Increment by exactly 1 frame duration per tick
        frameCount += 1
        let current = baseTimelineTime + Double(frameCount) * frameTimebase.frameDuration.seconds * rate
        let hostTime = CACurrentMediaTime()
        let dtMs = frameCount > 1 ? ((hostTime - baseHostTime) / Double(frameCount)) * 1000.0 : 0
        lastEmittedTime = current

        // TELEMETRY: Log first 10 ticks to verify display-sync timing
        if frameCount <= 10 {
            let expectedInterval = frameTimebase.frameDuration.seconds
            let actualInterval = frameCount > 1 ? (hostTime - baseHostTime) / Double(frameCount) : 0
            print("⏱️  [TimelineTicker] Tick #\(frameCount): " +
                  "time=\(String(format: "%.4f", current))s, " +
                  "expected=\(String(format: "%.4f", expectedInterval))s, " +
                  "actual=\(String(format: "%.4f", actualInterval))s")
        }

        // A/V Sync Diagnostics
        AVSyncDiagnostics.shared.logTick(hostTime: hostTime, dtMs: dtMs, rate: rate, 
                                        timeline: current, mono: true)

        // Feed the ticker time to PlaybackClock to keep it synchronized
        PlaybackClock.shared.align(to: current, hostTime: hostTime, source: .transport)

        handler(current)
    }

    private func currentTimelineTime() -> TimeInterval {
        guard isRunning else { return lastEmittedTime }
        // FRAME-ACCURATE: Use frame counter, not realtime
        return baseTimelineTime + Double(frameCount) * frameTimebase.frameDuration.seconds * rate
    }
}
