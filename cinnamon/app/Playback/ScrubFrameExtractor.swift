import AVFoundation

/// Lightweight decoder used for scrubbing. Each request operates on a small
/// independent `AVAssetReader` window so that playback decoding can continue
/// uninterrupted.
actor ScrubFrameExtractor {
    struct Configuration {
        let lookahead: TimeInterval
        let lookbehind: TimeInterval
        let pixelFormat: OSType
        let preferredTimescale: CMTimeScale
        let tolerance: TimeInterval
        let cacheCapacity: Int

        static var `default`: Configuration {
            Configuration(lookahead: 0.75,
                          lookbehind: 0.35,
                          pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          preferredTimescale: 600,
                          tolerance: 1.0 / 120.0,
                          cacheCapacity: 12)
        }
    }

    private struct CacheEntry {
        let timelineTime: TimeInterval
        let frame: VideoSource.DecodedFrame
        let version: UInt64?
    }

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let sourceRange: ClosedRange<TimeInterval>
    private let configuration: Configuration

    private var cache: [CacheEntry] = []

    init(asset: AVAsset,
         track: AVAssetTrack,
         sourceRange: ClosedRange<TimeInterval>,
         configuration: Configuration = .default) {
        self.asset = asset
        self.track = track
        self.sourceRange = sourceRange
        self.configuration = configuration
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: true)
    }

    func requestFrame(at assetTime: TimeInterval,
                      targetTimelineTime: TimeInterval,
                      version: UInt64?,
                      buildFrame: (_ samplePTS: TimeInterval, _ pixelBuffer: CVPixelBuffer) -> VideoSource.DecodedFrame) throws -> VideoSource.DecodedFrame? {
        if let cached = cachedFrame(near: targetTimelineTime, version: version) {
            return cached
        }

        let start = max(sourceRange.lowerBound, assetTime - configuration.lookbehind)
        let end = min(sourceRange.upperBound, assetTime + configuration.lookahead)
        let duration = max(0.1, end - start)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: configuration.preferredTimescale),
                                       duration: CMTime(seconds: duration, preferredTimescale: configuration.preferredTimescale))

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: configuration.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = true

        guard reader.canAdd(output) else {
            throw NSError(domain: "ScrubFrameExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }

        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "ScrubFrameExtractor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        var previous: VideoSource.DecodedFrame?
        let tolerance = configuration.tolerance

        while let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let frame = buildFrame(samplePTS, pixelBuffer)

            // NEAREST-PREVIOUS: Choose frame at or before target time
            // Use strict > comparison to avoid selecting future frames
            if frame.timelineTime > targetTimelineTime + tolerance {
                // Current frame is in the future beyond tolerance
                if let previous {
                    // Return the previous frame (at or before target)
                    store(frame: previous, version: version)
                    
                    // A/V Sync Diagnostics: Log frame selection
                    let valid = previous.timelineTime <= targetTimelineTime + tolerance
                    Task { @MainActor in
                        AVSyncDiagnostics.shared.logSelection(
                            time: targetTimelineTime,
                            clipID: UUID(),
                            selectedPTS: previous.timelineTime,
                            nextPTS: frame.timelineTime,
                            valid: valid
                        )
                    }
                    
                    return previous
                } else {
                    // No previous frame yet, keep reading
                    previous = frame
                    continue
                }
            }

            // Current frame is at or before target (or within tolerance after)
            // Keep it as candidate and continue reading
            previous = frame
        }

        // Return the last frame we found (closest to target without going over)
        if let previous {
            store(frame: previous, version: version)
            
            // A/V Sync Diagnostics: Log final selection
            let valid = previous.timelineTime <= targetTimelineTime + tolerance
            Task { @MainActor in
                AVSyncDiagnostics.shared.logSelection(
                    time: targetTimelineTime,
                    clipID: UUID(),
                    selectedPTS: previous.timelineTime,
                    nextPTS: nil,
                    valid: valid
                )
            }
            
            return previous
        }

        return nil
    }

    private func cachedFrame(near timelineTime: TimeInterval, version: UInt64?) -> VideoSource.DecodedFrame? {
        guard !cache.isEmpty else { return nil }
        let tolerance = configuration.tolerance
        var best: CacheEntry?
        var bestDelta = Double.greatestFiniteMagnitude

        for entry in cache {
            if let version, let entryVersion = entry.version, entryVersion != version {
                continue
            }
            let delta = abs(entry.timelineTime - timelineTime)
            guard delta <= tolerance else { continue }
            if delta < bestDelta {
                bestDelta = delta
                best = entry
            }
        }

        return best?.frame
    }

    private func store(frame: VideoSource.DecodedFrame, version: UInt64?) {
        cache.append(CacheEntry(timelineTime: frame.timelineTime, frame: frame, version: version))
        if cache.count > configuration.cacheCapacity {
            cache.removeFirst(cache.count - configuration.cacheCapacity)
        }
    }
}
