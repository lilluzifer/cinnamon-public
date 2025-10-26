import AVFoundation
import CoreVideo
import Accelerate

/// Frame decoder using AVAssetImageGenerator with strict NP enforcement.
actor ImageGeneratorDecoder {
    let asset: AVAsset
    private let clipID: UUID
    private var imageGenerator: AVAssetImageGenerator?
    private let frameDuration: Double
    private let assetDurationSeconds: Double
    private let pixelDimensions: (width: Int, height: Int)

    init(asset: AVAsset, clipID: UUID) {
        self.asset = asset
        self.clipID = clipID

        if let track = asset.tracks(withMediaType: .video).first {
            self.frameDuration = ImageGeneratorDecoder.deriveFrameDuration(from: track)
            self.pixelDimensions = ImageGeneratorDecoder.derivePixelDimensions(from: track)
        } else {
            self.frameDuration = 1.0 / 24.0
            self.pixelDimensions = (width: 1920, height: 1080)
        }

        self.assetDurationSeconds = ImageGeneratorDecoder.safeDurationSeconds(for: asset)

        self.imageGenerator = makeGenerator()
    }

    /// Decodes frame at target time with NP-aligned request.
    func decodeFrame(at targetTime: TimeInterval) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        let primaryRequest = ImageGeneratorDecoder.quantize(time: targetTime, frameDuration: frameDuration)
        let upperBound = assetDurationSeconds.isFinite ? max(assetDurationSeconds - frameDuration, 0) : primaryRequest
        let clampedPrimary = ImageGeneratorDecoder.clamp(time: primaryRequest, lowerBound: 0, upperBound: upperBound)
        let clampedTarget = ImageGeneratorDecoder.clamp(time: targetTime, lowerBound: 0, upperBound: upperBound)
        let ceilCandidate = ImageGeneratorDecoder.clamp(time: clampedPrimary + frameDuration, lowerBound: 0, upperBound: upperBound)
        let ceil2Candidate = ImageGeneratorDecoder.clamp(time: clampedPrimary + frameDuration * 2.0, lowerBound: 0, upperBound: upperBound)
        let fallbackTime = max(clampedPrimary - frameDuration, 0)

        var uniqueKeys: Set<Int64> = []
        var requestTimes: [Double] = []

        func appendCandidate(_ time: Double) {
            guard time.isFinite else { return }
            let key = Int64((time * 1000.0).rounded())
            guard !uniqueKeys.contains(key) else { return }
            uniqueKeys.insert(key)
            requestTimes.append(time)
        }

        appendCandidate(clampedPrimary)
        if ceilCandidate > clampedPrimary + 1e-6 {
            appendCandidate(ceilCandidate)
        }
        if ceil2Candidate > ceilCandidate + 1e-6 {
            appendCandidate(ceil2Candidate)
        }
        if abs(clampedTarget - clampedPrimary) > 1e-6 {
            appendCandidate(clampedTarget)
        }
        if fallbackTime < clampedPrimary - 1e-6 {
            appendCandidate(fallbackTime)
        }

        requestTimes.sort { lhs, rhs in
            let lhsDelta = abs(lhs - targetTime)
            let rhsDelta = abs(rhs - targetTime)
            if abs(lhsDelta - rhsDelta) < 1e-6 {
                return lhs > rhs  // prefer spätere Zeit bei gleichem Delta
            }
            return lhsDelta < rhsDelta
        }

        print("🎯 [ImageGeneratorDecoder] Requested frame t=\(String(format: "%.3f", targetTime))s (aligned=\(String(format: "%.3f", clampedPrimary))s)")

        guard let generator = imageGenerator else {
            throw NSError(domain: "ImageGeneratorDecoder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Generator not available"])
        }

        let acceptableDelta = max(frameDuration * 0.5, 0.012)
        let (cgImage, actualPTS) = try await generateBestImage(generator: generator,
                                                               requestTimes: requestTimes,
                                                               targetTime: targetTime,
                                                               acceptableDelta: acceptableDelta)
        imageGenerator = makeGenerator()
        let buffer = try createPixelBuffer(from: cgImage)
        if actualPTS > targetTime + 0.001 {
            print("   ⚠️ NP-VIOLATION: actual=\(String(format: "%.3f", actualPTS)) > target=\(String(format: "%.3f", targetTime))")
        }
        let deltaMS = (actualPTS - targetTime) * 1000
        print("   ✅ Selected frame at t=\(String(format: "%.3f", actualPTS))s (Δtarget=\(String(format: "%.1f", deltaMS))ms)")
        return (buffer, actualPTS)
    }

    func invalidate() async {
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
    }

    // MARK: - Helpers

    private static func deriveFrameDuration(from track: AVAssetTrack) -> Double {
        if track.minFrameDuration.isValid && !track.minFrameDuration.isIndefinite && track.minFrameDuration.seconds > 0 {
            return track.minFrameDuration.seconds
        }
        let fps = track.nominalFrameRate
        if fps > 0 {
            return 1.0 / Double(fps)
        }
        return 1.0 / 24.0
    }

    private static func derivePixelDimensions(from track: AVAssetTrack) -> (Int, Int) {
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let width = max(Int(abs(transformed.width.rounded())), 1)
        let height = max(Int(abs(transformed.height.rounded())), 1)
        return (width, height)
    }

    private static func safeDurationSeconds(for asset: AVAsset) -> Double {
        let duration = asset.duration
        guard duration.isValid && !duration.isIndefinite else { return .infinity }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : .infinity
    }

    private static func quantize(time: TimeInterval, frameDuration: Double) -> TimeInterval {
        guard frameDuration > 0 else { return max(time, 0) }
        let index = (time / frameDuration).rounded()
        return index * frameDuration
    }

    private static func clamp(time: TimeInterval, lowerBound: TimeInterval, upperBound: TimeInterval) -> TimeInterval {
        guard upperBound.isFinite else { return max(time, lowerBound) }
        return min(max(time, lowerBound), upperBound)
    }

    private func generateBestImage(generator: AVAssetImageGenerator,
                                   requestTimes: [Double],
                                   targetTime: TimeInterval,
                                   acceptableDelta: Double) async throws -> (CGImage, TimeInterval) {
        return try await withCheckedThrowingContinuation { continuation in
            let times = requestTimes.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
            if times.isEmpty {
                continuation.resume(throwing: NSError(domain: "ImageGeneratorDecoder",
                                                       code: -3,
                                                       userInfo: [NSLocalizedDescriptionKey: "No request times provided"]))
                return
            }

            let lock = NSLock()
            var remaining = times.count
            var bestImage: CGImage?
            var bestActual: TimeInterval = .infinity
            var bestDelta = Double.infinity
            var lastError: Error?
            var resumed = false

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTimeValue, image, actualTime, result, error in
                lock.lock()
                defer { lock.unlock() }

                if resumed { return }

                let requestSeconds = requestedTimeValue.seconds
                let requestedIndex = requestTimes.firstIndex { abs($0 - requestSeconds) < 1e-6 } ?? 0
                switch result {
                case .succeeded:
                    guard let image else { break }
                    let actual = actualTime.seconds
                    let errorMS = abs(actual - requestSeconds) * 1000
                    let attemptLabel = requestedIndex == 0 ? "primary" : "cand\(requestedIndex)"
                    print("   ✅ Found frame (\(attemptLabel)) at t=\(String(format: "%.3f", actual))s (error=\(String(format: "%.1f", errorMS))ms vs request)")

                    let deltaToTarget = abs(actual - targetTime)
                    if deltaToTarget <= acceptableDelta {
                        resumed = true
                        generator.cancelAllCGImageGeneration()
                        continuation.resume(returning: (image, actual))
                        return
                    }

                    if deltaToTarget < bestDelta {
                        bestDelta = deltaToTarget
                        bestActual = actual
                        bestImage = image
                    }
                case .failed:
                    if let error {
                        lastError = error
                        print("   ❌ Decode attempt failed at \(String(format: "%.3f", requestSeconds))s: \(error.localizedDescription)")
                    } else {
                        print("   ❌ Decode attempt failed at \(String(format: "%.3f", requestSeconds))s: image generation failed")
                    }
                case .cancelled:
                    break
                @unknown default:
                    break
                }

                remaining -= 1
                if remaining == 0 && !resumed {
                    resumed = true
                    generator.cancelAllCGImageGeneration()
                    if let image = bestImage {
                        print("   ⚠️ Using best-effort frame at t=\(String(format: "%.3f", bestActual))s (Δtarget=\(String(format: "%.1f", bestDelta * 1000))ms)")
                        continuation.resume(returning: (image, bestActual))
                    } else if let error = lastError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: NSError(domain: "ImageGeneratorDecoder",
                                                               code: -4,
                                                               userInfo: [NSLocalizedDescriptionKey: "No frame generated"]))
                    }
                }
            }
        }
    }

    private func makeGenerator() -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .encodedPixels
        let aheadTolerance = CMTime(seconds: frameDuration * 0.35, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = aheadTolerance

        let pastTolerance = CMTime(seconds: frameDuration * 0.65, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = pastTolerance

        if pixelDimensions.width > 0 && pixelDimensions.height > 0 {
            generator.maximumSize = CGSize(width: CGFloat(pixelDimensions.width),
                                           height: CGFloat(pixelDimensions.height))
        }

        return generator
    }

    private func createPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var bgra: CVPixelBuffer?
        let bgraStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                             image.width,
                                             image.height,
                                             kCVPixelFormatType_32BGRA,
                                             [
                                                 kCVPixelBufferCGImageCompatibilityKey as String: true,
                                                 kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                                 kCVPixelBufferMetalCompatibilityKey as String: true,
                                                 kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                                             ] as CFDictionary,
                                             &bgra)
        guard bgraStatus == kCVReturnSuccess, let bgra else {
            throw NSError(domain: "ImageGeneratorDecoder", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate pixel buffer"])
        }

        CVPixelBufferLockBaseAddress(bgra, [])
        defer { CVPixelBufferUnlockBaseAddress(bgra, []) }

        guard let base = CVPixelBufferGetBaseAddress(bgra) else {
            throw NSError(domain: "ImageGeneratorDecoder", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid BGRA base address"])
        }

        guard let context = CGContext(data: base,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw NSError(domain: "ImageGeneratorDecoder", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create BGRA context"])
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bgra
    }


    func nativeFrameDuration() -> Double {
        frameDuration
    }
}
