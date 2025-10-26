import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox

/// Experimental compressed-sample scrub engine. Reads compressed GOP windows
/// and decodes them forward via the shared PersistentVTSession, while exposing
/// a ring buffer that can be traversed in reverse without re-entering
/// AVAssetReader's heuristics.
actor CompressedScrubEngine {

    struct CachedFrame {
        let pts: TimeInterval
        let pixelBuffer: CVPixelBuffer
    }

    enum EngineError: Error {
        case cacheMiss
    }

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config
    private let gopAnalyzer: GOPAnalyzer
    private let maxCacheFrames: Int = 48
    private let prefetchDuration: TimeInterval = 2.0
    private let assetDuration: TimeInterval
    private var cachedFrames: [CachedFrame] = []
    private var currentRange: ClosedRange<TimeInterval>?
    private var currentRAKey: RAKey?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var lastPrefetchCenter: TimeInterval = -1

    init(asset: AVAsset,
         track: AVAssetTrack,
         clipID: UUID,
         config: ScrubFeatureFlags.Config,
         gopAnalyzer: GOPAnalyzer) {
        self.asset = asset
        self.track = track
        self.clipID = clipID
        self.config = config
        self.gopAnalyzer = gopAnalyzer
        self.assetDuration = CompressedScrubEngine.deriveDuration(for: asset)
    }

    func invalidate() {
        reader?.cancelReading()
        reader = nil
        output = nil
        cachedFrames.removeAll(keepingCapacity: true)
        currentRange = nil
        currentRAKey = nil
        lastPrefetchCenter = -1
    }

    func decodeFrame(randomAccess: GOPAnalyzer.RandomAccessResult,
                     targetPTS: TimeInterval,
                     direction: ScrubCoordinator.ScrubDirection,
                     vtSession: PersistentVTSession,
                     requireCache: Bool = false,
                     maxDistance: TimeInterval = 0.5) async throws -> (CVPixelBuffer, TimeInterval) {
        if let (cached, index) = peekCachedFrame(targetPTS: targetPTS, direction: direction) {
            let distance = abs(cached.pts - targetPTS)
            if distance <= maxDistance {
                if let consumed = consumeCachedFrame(at: index, direction: direction) {
                    return consumed
                }
            } else if requireCache {
                throw EngineError.cacheMiss
            }
        } else if requireCache {
            throw EngineError.cacheMiss
        }

        if requireCache {
            throw EngineError.cacheMiss
        }

        try await prefetchGOP(randomAccess: randomAccess,
                              targetPTS: targetPTS,
                              direction: direction,
                              vtSession: vtSession)

        if let frame = frameFromCache(targetPTS: targetPTS, direction: direction) {
            return frame
        }

        throw NSError(domain: "CompressedScrubEngine", code: -500,
                      userInfo: [NSLocalizedDescriptionKey: "Unable to provide frame after prefetch"])
    }

    private func peekCachedFrame(targetPTS: TimeInterval,
                                 direction: ScrubCoordinator.ScrubDirection) -> (CachedFrame, Int)? {
        guard !cachedFrames.isEmpty else { return nil }
        switch direction {
        case .reverse:
            if let index = cachedFrames.lastIndex(where: { $0.pts <= targetPTS + 0.0005 }) {
                return (cachedFrames[index], index)
            }
            if let first = cachedFrames.first {
                return (first, 0)
            }
            return nil
        case .forward:
            if let index = cachedFrames.firstIndex(where: { $0.pts >= targetPTS - 0.0005 }) {
                return (cachedFrames[index], index)
            }
            if let last = cachedFrames.last {
                return (last, cachedFrames.count - 1)
            }
            return nil
        }
    }

    private func consumeCachedFrame(at index: Int,
                                    direction: ScrubCoordinator.ScrubDirection) -> (CVPixelBuffer, TimeInterval)? {
        guard cachedFrames.indices.contains(index) else { return nil }
        let frame = cachedFrames[index]
        switch direction {
        case .reverse:
            if index + 1 < cachedFrames.count {
                cachedFrames.removeSubrange((index + 1)..<cachedFrames.count)
            }
        case .forward:
            if index > 0 {
                cachedFrames.removeSubrange(0..<index)
            }
        }
        currentRange = cachedFrames.first.flatMap { start in
            cachedFrames.last.map { end in
                start.pts...end.pts
            }
        }
        return (frame.pixelBuffer, frame.pts)
    }

    private func frameFromCache(targetPTS: TimeInterval,
                                direction: ScrubCoordinator.ScrubDirection) -> (CVPixelBuffer, TimeInterval)? {
        guard let (_, index) = peekCachedFrame(targetPTS: targetPTS, direction: direction) else {
            return nil
        }
        return consumeCachedFrame(at: index, direction: direction)
    }

    private func prefetchGOP(randomAccess: GOPAnalyzer.RandomAccessResult,
                             targetPTS: TimeInterval,
                             direction: ScrubCoordinator.ScrubDirection,
                             vtSession: PersistentVTSession) async throws {
        // Avoid re-prefetching for the same RA unless target moved significantly.
        if let key = currentRAKey,
           key == randomAccess.key,
           abs(targetPTS - lastPrefetchCenter) < 0.25,
           !cachedFrames.isEmpty {
            return
        }

        reader?.cancelReading()
        reader = nil
        output = nil
        cachedFrames.removeAll(keepingCapacity: true)

        let start = max(0.0, randomAccess.pts.isFinite ? randomAccess.pts : max(targetPTS - 0.5, 0))
        let duration = min(prefetchDuration, assetDuration - start)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 24000),
            duration: CMTime(seconds: duration, preferredTimescale: 24000)
        )

        let newReader = try AVAssetReader(asset: asset)
        let compressedOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if track.mediaType == .video {
            compressedOutput.supportsRandomAccess = true
        }

        guard newReader.canAdd(compressedOutput) else {
            throw NSError(domain: "CompressedScrubEngine", code: -501,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add compressed output"])
        }
        newReader.add(compressedOutput)
        newReader.timeRange = timeRange

        guard newReader.startReading() else {
            let error = newReader.error ?? NSError(domain: "CompressedScrubEngine", code: -502,
                                                   userInfo: [NSLocalizedDescriptionKey: "startReading failed"])
            throw error
        }

        reader = newReader
        output = compressedOutput
        currentRAKey = randomAccess.key
        lastPrefetchCenter = targetPTS

        var frames: [CachedFrame] = []
        var consumedSync = false
        let vtDirection: ScrubDirection = direction == .reverse ? .backward : .forward

        while frames.count < maxCacheFrames,
              let sampleBuffer = compressedOutput.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            if !consumedSync {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                   let first = attachments.first {
                    let isSync = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                    if !isSync {
                        continue
                    }
                    consumedSync = true
                }
            }

            guard CMSampleBufferGetFormatDescription(sampleBuffer) != nil else {
                print("[COMPRESSED_ENGINE] skipping sample without format description")
                continue
            }

            var attempt = 0
            var decodedFrame: CachedFrame?

            while attempt < 3 && decodedFrame == nil {
                attempt += 1
                do {
                    let result = try await vtSession.decode(sampleBuffer: sampleBuffer, direction: vtDirection)
                    decodedFrame = CachedFrame(pts: result.pts, pixelBuffer: result.pixelBuffer)
                } catch {
                    let nsError = error as NSError
                    if nsError.code == -101 {
                        print("[COMPRESSED_ENGINE] ignored sample due to missing format description during decode")
                        break
                    }
                    if nsError.code == Int(kVTVideoDecoderMalfunctionErr) {
                        print("[COMPRESSED_ENGINE] VT malfunction (attempt \(attempt)), waiting for session recovery")
                        do {
                            try await Task.sleep(nanoseconds: 5_000_000)
                            try await vtSession.ensureSession()
                        } catch {
                            print("[COMPRESSED_ENGINE] failed to recover VT session: \(error)")
                            break
                        }
                        continue
                    }
                    print("[COMPRESSED_ENGINE] decode error: \(error)")
                    break
                }
            }

            if let frame = decodedFrame {
                frames.append(frame)
            } else if attempt >= 3 {
                print("[COMPRESSED_ENGINE] giving up on current GOP after repeated decode failures")
                break
            } else {
                // failure due to skipped sample; proceed to next sample
                continue
            }
        }

        frames.sort { $0.pts < $1.pts }
        cachedFrames = frames
        currentRange = frames.first.flatMap { first in
            frames.last.map { last in
                first.pts...last.pts
            }
        }

        if frames.isEmpty {
            throw NSError(domain: "CompressedScrubEngine", code: -503,
                          userInfo: [NSLocalizedDescriptionKey: "Prefetch produced no frames"])
        }
    }
}

private extension CompressedScrubEngine {
    static func deriveDuration(for asset: AVAsset) -> TimeInterval {
        guard asset.duration.isNumeric else { return 0 }
        return max(asset.duration.seconds, 0)
    }
}
