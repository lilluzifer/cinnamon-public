import AVFoundation

/// Maintains a sliding-window `AVAssetReader` to serve continuous playback
/// without destroying and re-creating the reader on every small seek.
final class PlaybackReader {
    struct Configuration {
        let windowRadius: TimeInterval
        let pixelFormat: OSType
        let preferredTimescale: CMTimeScale
        let tolerance: TimeInterval

        static var `default`: Configuration {
            Configuration(windowRadius: 5.0,
                          pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          preferredTimescale: 600,
                          tolerance: 1.0 / 240.0)
        }
    }

    private struct SampledFrame {
        let frame: VideoSource.DecodedFrame
        let assetPTS: TimeInterval
    }

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let sourceRange: ClosedRange<TimeInterval>
    private let configuration: Configuration

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var window: ClosedRange<TimeInterval>?
    private var lastDeliveredPTS: TimeInterval?
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["PLAYBACK_READER_DEBUG"] == "1"
    private let slowWindowThreshold: CFTimeInterval = 0.05

    init(asset: AVAsset,
         track: AVAssetTrack,
         sourceRange: ClosedRange<TimeInterval>,
         configuration: Configuration = .default) {
        self.asset = asset
        self.track = track
        self.sourceRange = sourceRange
        self.configuration = configuration
    }

    func invalidate() {
        reader?.cancelReading()
        reader = nil
        output = nil
        window = nil
        lastDeliveredPTS = nil
    }

    /// Returns the decoded frame for the requested asset time. If the
    /// requested time stays inside the current window the reader continues
    /// streaming; otherwise the window shifts to the new position.
    func copyFrame(at assetTime: TimeInterval,
                   targetTimelineTime: TimeInterval,
                   buildFrame: (_ samplePTS: TimeInterval, _ pixelBuffer: CVPixelBuffer) -> VideoSource.DecodedFrame) throws -> VideoSource.DecodedFrame? {
        try ensureWindow(for: assetTime)
        guard let output else { return nil }

        var previous: SampledFrame?
        let tolerance = configuration.tolerance

        while let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let frame = buildFrame(samplePTS, pixelBuffer)
            let sampled = SampledFrame(frame: frame, assetPTS: samplePTS)

            // NEAREST-PREVIOUS: Choose frame at or before target time
            // Use strict > comparison to avoid selecting future frames
            if frame.timelineTime > targetTimelineTime + tolerance {
                // Current frame is in the future beyond tolerance
                if let previous {
                    // Return the previous frame (at or before target)
                    lastDeliveredPTS = previous.assetPTS
                    
                    // A/V Sync Diagnostics: Log frame selection
                    // Valid if frame is at or before target, or within tolerance after
                    let valid = previous.frame.timelineTime <= targetTimelineTime + tolerance
                    Task { @MainActor in
                        AVSyncDiagnostics.shared.logSelection(
                            time: targetTimelineTime,
                            clipID: UUID(),
                            selectedPTS: previous.frame.timelineTime,
                            nextPTS: frame.timelineTime,
                            valid: valid
                        )
                    }
                    
                    return previous.frame
                } else {
                    // No previous frame yet, keep reading
                    previous = sampled
                    continue
                }
            }

            // Current frame is at or before target (or within tolerance after)
            // Keep it as candidate and continue reading
            previous = sampled
        }

        // Return the last frame we found (closest to target without going over)
        if let previous {
            lastDeliveredPTS = previous.assetPTS
            
            // A/V Sync Diagnostics: Log final selection
            let valid = previous.frame.timelineTime <= targetTimelineTime + tolerance
            Task { @MainActor in
                AVSyncDiagnostics.shared.logSelection(
                    time: targetTimelineTime,
                    clipID: UUID(),
                    selectedPTS: previous.frame.timelineTime,
                    nextPTS: nil,
                    valid: valid
                )
            }
            
            return previous.frame
        }

        return nil
    }

    private func ensureWindow(for assetTime: TimeInterval) throws {
        let needsNewWindow: Bool
        if let window {
            let outsideWindow = assetTime < window.lowerBound || assetTime > window.upperBound
            let jumpedBackwards = lastDeliveredPTS.map { assetTime + configuration.tolerance < $0 } ?? false
            needsNewWindow = outsideWindow || jumpedBackwards
        } else {
            needsNewWindow = true
        }

        guard needsNewWindow else { return }

        reader?.cancelReading()

        let maxLookAhead = max(configuration.windowRadius, 1.0)
        let dynamicLookBehind = min(configuration.windowRadius * 0.25,
                                    max(configuration.tolerance * 12.0, 0.08))
        let start = max(sourceRange.lowerBound, assetTime - dynamicLookBehind)
        let end = min(sourceRange.upperBound, assetTime + maxLookAhead)
        let duration = max(0.1, end - start)
        let windowStartTime = CACurrentMediaTime()

        let newReader = try AVAssetReader(asset: asset)
        newReader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: configuration.preferredTimescale),
                                          duration: CMTime(seconds: duration, preferredTimescale: configuration.preferredTimescale))

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: configuration.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        newOutput.alwaysCopiesSampleData = true

        guard newReader.canAdd(newOutput) else {
            throw NSError(domain: "PlaybackReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }
        newReader.add(newOutput)
        guard newReader.startReading() else {
            throw NSError(domain: "PlaybackReader", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        reader = newReader
        output = newOutput
        window = start...end
        lastDeliveredPTS = nil

        if debugLoggingEnabled {
            let windowDuration = CACurrentMediaTime() - windowStartTime
            if windowDuration > slowWindowThreshold {
                let clipRange = String(format: "%.3f-%.3f", start, end)
                print("🪟 [PlaybackReader] New window created (range=\(clipRange), duration=\(String(format: "%.1f", duration))s) in \(String(format: "%.1f", windowDuration * 1000))ms")
            } else {
                print("🪟 [PlaybackReader] New window created quickly (range=\(String(format: "%.3f-%.3f", start, end)))")
            }
        }
    }
}
