import AVFoundation
import QuartzCore
import Darwin

/// Provides multi-layer audio playback by routing every active clip through an
/// `AVAudioEngine`. The mixer owns per-clip `AVAudioPlayerNode`s that can be
/// restarted on seeks and scrubs so timeline playback stays in sync.
final class TimelineAudioMixer {
    private struct Channel {
        let clipID: UUID
        let player: AVAudioPlayerNode
        let audioFile: AVAudioFile
        var activeSegmentID: UUID?
        var lastScheduledStart: TimeInterval
    }

    private let engine = AVAudioEngine()
    private var engineConfigured = false
    private var channels: [UUID: Channel] = [:]
    private var muted = false
    private var clockState: PlaybackClock.State?
    private let playbackClock = PlaybackClock.shared

    init() {
        configureEngineGraph()
    }

    func reset() {
        stopAll()
        for channel in channels.values {
            detach(channel: channel)
        }
        channels.removeAll()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        engine.mainMixerNode.outputVolume = muted ? 0.0 : 1.0
        if muted {
            pauseAll()
        } else if !channels.isEmpty {
            startEngineIfNeeded()
        }
    }

    func pauseAll() {
        channels.values.forEach { $0.player.pause() }
    }

    func stopAll() {
        channels = channels.mapValues { channel in
            channel.player.stop()
            return Channel(clipID: channel.clipID,
                           player: channel.player,
                           audioFile: channel.audioFile,
                           activeSegmentID: nil,
                           lastScheduledStart: 0)
        }
    }

    func seek(to _: TimeInterval) {
        stopAll()
    }

    func updateClockState(_ state: PlaybackClock.State) {
        clockState = state
    }

    func activate(segments: [TimelineSegment],
                  timelineTime: TimeInterval,
                  rate: Double,
                  isPlaying: Bool) {
        let clipSegments = segments.compactMap { $0.clip }
        let desiredIDs = Set(clipSegments.map(\.id))

        removeObsoleteChannels(keeping: desiredIDs)

        guard !muted, isPlaying, rate > 0, !segments.isEmpty else {
            pauseAll()
            return
        }

        // A/V Sync Diagnostics: Log audio clock state
        if engine.isRunning, let outputNode = engine.outputNode as? AVAudioNode {
            let sampleRate = outputNode.outputFormat(forBus: 0).sampleRate
            let ioBufferDuration = engine.outputNode.presentationLatency
            let audioTime = engine.outputNode.lastRenderTime ?? AVAudioTime(hostTime: 0)
            let audioSeconds = Double(audioTime.sampleTime) / sampleRate
            let audioClock = CMTime(seconds: audioSeconds, preferredTimescale: 600)
            AVSyncDiagnostics.shared.logAudioClock(deviceSampleRate: sampleRate, 
                                                  ioBuffer: Int(ioBufferDuration * sampleRate),
                                                  audioClock: audioClock, 
                                                  timeline: timelineTime)
        }

        for segment in segments {
            guard let clip = segment.clip else { continue }
            guard var channel = ensureChannel(for: clip) else { continue }

            let assetTime = TimelineAudioMixer.assetTime(for: clip, at: timelineTime)
            let requiresReschedule = channel.activeSegmentID != segment.id ||
                abs(channel.lastScheduledStart - assetTime) > 0.02 ||
                !channel.player.isPlaying

            if requiresReschedule {
                schedule(channel: &channel,
                         clip: clip,
                         startSeconds: assetTime,
                         segmentID: segment.id)
            }

            if isPlaying {
                schedulePlaybackIfNeeded(for: &channel,
                                         timelineTime: timelineTime,
                                         nominalRate: rate)
            } else {
                channel.player.pause()
            }

            channels[clip.id] = channel
        }
    }

    // MARK: - Private

    private func ensureChannel(for clip: Clip) -> Channel? {
        if let existing = channels[clip.id] {
            return existing
        }

        guard let url = resolvedURL(for: clip) else { return nil }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
            let channel = Channel(clipID: clip.id,
                                  player: player,
                                  audioFile: audioFile,
                                  activeSegmentID: nil,
                                  lastScheduledStart: 0)
            channels[clip.id] = channel
            startEngineIfNeeded()
            return channel
        } catch {
            print("[AudioMixer] Failed to open audio for clip \(clip.id): \(error)")
            return nil
        }
    }

    private func schedule(channel: inout Channel,
                          clip: Clip,
                          startSeconds: TimeInterval,
                          segmentID: UUID) {
        let player = channel.player
        player.stop()

        let file = channel.audioFile
        let sampleRate = file.processingFormat.sampleRate
        let clipSrcStart = clip.srcRange.start.seconds
        let clipSrcEnd = clip.srcRange.end.seconds
        let clampedStart = min(max(startSeconds, clipSrcStart), clipSrcEnd)
        let remainingSeconds = max(clipSrcEnd - clampedStart, 0)
        guard remainingSeconds > 0 else { return }

        let startFrameInSource = AVAudioFramePosition((clampedStart - clipSrcStart) * sampleRate)
        let frameCount = AVAudioFrameCount(remainingSeconds * sampleRate)

        player.scheduleSegment(file,
                               startingFrame: startFrameInSource,
                               frameCount: frameCount,
                               at: nil,
                               completionHandler: nil)

        channel.activeSegmentID = segmentID
        channel.lastScheduledStart = clampedStart
    }

    private func schedulePlaybackIfNeeded(for channel: inout Channel,
                                          timelineTime: TimeInterval,
                                          nominalRate: Double) {
        startEngineIfNeeded()
        let player = channel.player
        guard !player.isPlaying else { return }

        guard let state = clockState, state.isPlaying else {
            player.play()
            return
        }

        let referenceRate = abs(state.rate) > .ulpOfOne ? state.rate : nominalRate
        guard abs(referenceRate) > .ulpOfOne else {
            player.play()
            return
        }

        let offset = (timelineTime - state.time) / referenceRate
        let hostStartSeconds = state.hostTime + offset
        let nowSeconds = CACurrentMediaTime()
        let offsetSeconds = hostStartSeconds - nowSeconds

        if offsetSeconds > 0.002 {
            let offsetTicks = AVAudioTime.hostTime(forSeconds: offsetSeconds)
            let startHost = mach_absolute_time() &+ offsetTicks
            let startTime = AVAudioTime(hostTime: startHost)
            player.play(at: startTime)
        } else {
            player.play()
        }
    }

    private func removeObsoleteChannels(keeping desiredIDs: Set<UUID>) {
        let obsolete = Set(channels.keys).subtracting(desiredIDs)
        for clipID in obsolete {
            if let channel = channels.removeValue(forKey: clipID) {
                channel.player.stop()
                detach(channel: channel)
            }
        }
    }

    private func detach(channel: Channel) {
        engine.disconnectNodeInput(channel.player)
        engine.disconnectNodeOutput(channel.player)
        engine.detach(channel.player)
    }

    private func configureEngineGraph() {
        guard !engineConfigured else { return }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engineConfigured = true
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        configureEngineGraph()
        do {
            try engine.start()
        } catch {
            print("[AudioMixer] Failed to start engine: \(error)")
        }
    }

    private func resolvedURL(for clip: Clip) -> URL? {
        if let url = URL(string: clip.assetRef), url.isFileURL {
            return url
        }
        let fileURL = URL(fileURLWithPath: clip.assetRef)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private static func assetTime(for clip: Clip,
                                  at timelineTime: TimeInterval) -> TimeInterval {
        let localTimeline = max(0, timelineTime - clip.dstStart)
        let speed = Double(max(clip.speed, 0.0001))
        let srcStart = clip.srcRange.start.seconds
        let srcDuration = clip.srcRange.duration.seconds
        let sourceTime = srcStart + localTimeline * speed
        return min(max(sourceTime, srcStart), srcStart + srcDuration)
    }
}
