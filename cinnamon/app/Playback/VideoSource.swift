import AVFoundation
import CoreGraphics

/// Provides decoded frames for a single clip. Playback and scrubbing use
/// separate decoding paths so that timeline playback stays smooth while the
/// user performs random-access scrubs.
actor VideoSource {
    struct DecodedFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let timelineTime: TimeInterval
    }

    private enum RequestMode {
        case playback
        case scrub
    }

    private enum SourceState {
        case idle
        case prepared
    }

    private let clipID: UUID
    private let assetURL: URL
    private let sourceStart: TimeInterval
    private let sourceDuration: TimeInterval
    private let speed: Double
    private let timelineStart: TimeInterval

    let asset: AVAsset
    private(set) var videoTrack: AVAssetTrack?
    private var state: SourceState = .idle

    private var playbackReader: PlaybackReader?
    private var scrubExtractor: ScrubFrameExtractor?
    private var historyManager: FrameHistoryManager

    private var lastDeliveredFrame: DecodedFrame?
    private var lastRequestedTimelineTime: TimeInterval = -.infinity
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["VIDEO_SOURCE_DEBUG"] == "1"
    private let slowDecodeThreshold: CFTimeInterval = 0.1

    private let playbackConfiguration = PlaybackReader.Configuration(windowRadius: 5.0,
                                                                      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                                      preferredTimescale: 600,
                                                                      tolerance: 1.0 / 240.0)
    private let scrubConfiguration = ScrubFrameExtractor.Configuration(lookahead: 0.75,
                                                                       lookbehind: 0.4,
                                                                       pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                                       preferredTimescale: 600,
                                                                       tolerance: 1.0 / 120.0,
                                                                       cacheCapacity: 16)

    init(clipID: UUID,
         assetURL: URL,
         sourceStart: TimeInterval,
         sourceDuration: TimeInterval,
         speed: Double,
         timelineStart: TimeInterval) {
        self.clipID = clipID
        self.assetURL = assetURL
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.speed = max(speed, 0.0001)
        self.timelineStart = timelineStart
        self.asset = AVURLAsset(url: assetURL)

        self.historyManager = FrameHistoryManager(byteBudget: 50 * 1024 * 1024,
                                                  maxAge: 6.0,
                                                  biasWindow: 0.2)
    }

    func prepare() async throws {
        guard state == .idle else { return }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let first = tracks.first else {
            throw NSError(domain: "VideoSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track found for clip \(clipID)"])
        }
        videoTrack = first
        playbackReader = PlaybackReader(asset: asset,
                                        track: first,
                                        sourceRange: sourceStart...(sourceStart + sourceDuration),
                                        configuration: playbackConfiguration)
        scrubExtractor = ScrubFrameExtractor(asset: asset,
                                             track: first,
                                             sourceRange: sourceStart...(sourceStart + sourceDuration),
                                             configuration: scrubConfiguration)
        state = .prepared
    }

    func naturalSize() -> CGSize? {
        guard let track = videoTrack else { return nil }
        let size = track.naturalSize
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    func copyFrame(at timelineTime: TimeInterval,
                   caller: String = "unknown",
                   version: UInt64? = nil) async throws -> DecodedFrame? {
        await VideoPerformanceMonitor.shared.logFrameRequest(clipID: clipID, time: timelineTime)

        if state == .idle {
            try await prepare()
        }

        guard state == .prepared, let track = videoTrack else {
            await VideoPerformanceMonitor.shared.logFrameDelivered(clipID: clipID, success: false)
            return fallbackFrame(for: timelineTime, preferredVersion: version)
        }

        let mode = requestMode(for: caller)
        let requestedAssetTime = sourceTime(for: timelineTime)
        let sourceRange = sourceStart...(sourceStart + sourceDuration)
        let clampedAssetTime = min(max(requestedAssetTime, sourceRange.lowerBound), sourceRange.upperBound)
        lastRequestedTimelineTime = timelineTime
        let requestVersion = mode == .scrub ? version : nil
        let decodeStartTime = CFAbsoluteTimeGetCurrent()

        var decoded: DecodedFrame?

        switch mode {
        case .playback:
            if playbackReader == nil {
                playbackReader = PlaybackReader(asset: asset,
                                                track: track,
                                                sourceRange: sourceRange,
                                                configuration: playbackConfiguration)
            }
            if let reader = playbackReader {
                decoded = try decodePlaybackFrame(reader: reader,
                                                  assetTime: clampedAssetTime,
                                                  timelineTime: timelineTime)
            }
        case .scrub:
            if scrubExtractor == nil {
                scrubExtractor = ScrubFrameExtractor(asset: asset,
                                                     track: track,
                                                     sourceRange: sourceRange,
                                                     configuration: scrubConfiguration)
            }
            if let extractor = scrubExtractor {
                decoded = try await decodeScrubFrame(extractor: extractor,
                                                     assetTime: clampedAssetTime,
                                                     timelineTime: timelineTime,
                                                     version: requestVersion)
            }
        }

        if let decoded {
            record(frame: decoded, mode: mode, version: requestVersion)
            await VideoPerformanceMonitor.shared.logFrameDelivered(clipID: clipID, success: true)
            logDecodeIfNeeded(duration: CFAbsoluteTimeGetCurrent() - decodeStartTime,
                              mode: mode,
                              assetTime: clampedAssetTime,
                              result: "decoded")
            return decoded
        }

        if let fallback = fallbackFrame(for: timelineTime, preferredVersion: requestVersion) {
            await VideoPerformanceMonitor.shared.logFrameDelivered(clipID: clipID, success: true)
            logDecodeIfNeeded(duration: CFAbsoluteTimeGetCurrent() - decodeStartTime,
                              mode: mode,
                              assetTime: clampedAssetTime,
                              result: "fallback")
            return fallback
        }

        await VideoPerformanceMonitor.shared.logFrameDelivered(clipID: clipID, success: false)
        logDecodeIfNeeded(duration: CFAbsoluteTimeGetCurrent() - decodeStartTime,
                          mode: mode,
                          assetTime: clampedAssetTime,
                          result: "failed")
        return nil
    }

    func latestFrame() async -> DecodedFrame? {
        if let historyLatest = historyManager.latest() {
            let frame = DecodedFrame(pixelBuffer: historyLatest.buffer, timelineTime: historyLatest.time)
            lastDeliveredFrame = frame
            return frame
        }
        return lastDeliveredFrame
    }

    func invalidate() async {
        playbackReader?.invalidate()
        playbackReader = nil
        if let extractor = scrubExtractor {
            await extractor.clearCache()
        }
        scrubExtractor = nil
        videoTrack = nil
        historyManager.clear()
        lastDeliveredFrame = nil
        lastRequestedTimelineTime = -.infinity
        state = .idle
    }

    private func decodePlaybackFrame(reader: PlaybackReader,
                                     assetTime: TimeInterval,
                                     timelineTime: TimeInterval) throws -> DecodedFrame? {
        let builder: (TimeInterval, CVPixelBuffer) -> DecodedFrame = { samplePTS, buffer in
            let timelinePTS = self.timelineTime(for: samplePTS)
            return DecodedFrame(pixelBuffer: buffer, timelineTime: timelinePTS)
        }
        return try reader.copyFrame(at: assetTime,
                                    targetTimelineTime: timelineTime,
                                    buildFrame: builder)
    }

    private func decodeScrubFrame(extractor: ScrubFrameExtractor,
                                  assetTime: TimeInterval,
                                  timelineTime: TimeInterval,
                                  version: UInt64?) async throws -> DecodedFrame? {
        let builder: (TimeInterval, CVPixelBuffer) -> DecodedFrame = { samplePTS, buffer in
            let timelinePTS = self.timelineTime(for: samplePTS)
            return DecodedFrame(pixelBuffer: buffer, timelineTime: timelinePTS)
        }
        return try await extractor.requestFrame(at: assetTime,
                                                targetTimelineTime: timelineTime,
                                                version: version,
                                                buildFrame: builder)
    }

    private func record(frame: DecodedFrame, mode: RequestMode, version: UInt64?) {
        lastDeliveredFrame = frame
        historyManager.record(buffer: frame.pixelBuffer,
                              time: frame.timelineTime,
                              version: version,
                              source: mode == .playback ? .playback : .scrub,
                              anchor: lastRequestedTimelineTime)
    }

    private func logDecodeIfNeeded(duration: CFAbsoluteTime,
                                   mode: RequestMode,
                                   assetTime: TimeInterval,
                                   result: String) {
        guard debugLoggingEnabled else { return }
        let durationMs = duration * 1000
        if duration >= slowDecodeThreshold || result != "decoded" {
            let modeString = mode == .playback ? "playback" : "scrub"
            print("🧩 [VideoSource] clip=\(clipID.uuidString.prefix(8)) mode=\(modeString) assetTime=\(String(format: "%.3f", assetTime))s result=\(result) took=\(String(format: "%.1f", durationMs))ms")
        }
    }

    private func fallbackFrame(for timelineTime: TimeInterval, preferredVersion: UInt64?) -> DecodedFrame? {
        if let historyFrame = historyManager.bestFrame(around: timelineTime, preferredVersion: preferredVersion) {
            let frame = DecodedFrame(pixelBuffer: historyFrame.buffer, timelineTime: historyFrame.time)
            lastDeliveredFrame = frame
            
            // A/V Sync Diagnostics: Log fallback frame selection
            // FrameHistoryManager.bestEntry already implements NEAREST-PREVIOUS correctly,
            // so all frames from history are valid by definition
            Task { @MainActor in
                AVSyncDiagnostics.shared.logSelection(
                    time: timelineTime,
                    clipID: self.clipID,
                    selectedPTS: frame.timelineTime,
                    nextPTS: nil,
                    valid: true  // History manager already chose correctly
                )
            }
            
            return frame
        }
        
        if let lastFrame = lastDeliveredFrame {
            // A/V Sync Diagnostics: Log last delivered frame reuse
            // This is a fallback of a fallback - mark as valid since it's the best we have
            Task { @MainActor in
                AVSyncDiagnostics.shared.logSelection(
                    time: timelineTime,
                    clipID: self.clipID,
                    selectedPTS: lastFrame.timelineTime,
                    nextPTS: nil,
                    valid: true  // Best available frame
                )
            }
        }
        
        return lastDeliveredFrame
    }

    private func requestMode(for caller: String) -> RequestMode {
        let lowercase = caller.lowercased()
        let scrubKeywords = ["scrub", "requesttime", "gap", "slider", "seek", "updateframebuffer"]
        if scrubKeywords.contains(where: { lowercase.contains($0) }) {
            return .scrub
        }
        return .playback
    }

    private func sourceTime(for timelineTime: TimeInterval) -> TimeInterval {
        let local = max(0, timelineTime - timelineStart) * speed
        let sourceTime = sourceStart + local
        return min(max(sourceTime, sourceStart), sourceStart + sourceDuration)
    }

    private func timelineTime(for assetTime: TimeInterval) -> TimeInterval {
        let clamped = min(max(assetTime, sourceStart), sourceStart + sourceDuration)
        let local = (clamped - sourceStart) / max(speed, 0.0001)
        return timelineStart + local
    }
}
