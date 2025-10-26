import AVFoundation
import CoreVideo
import IOSurface
import Metal
import MetalKit

/// Container for Y and CbCr textures from YCbCr video format
struct VideoTextures {
    let yTexture: MTLTexture
    let cbcrTexture: MTLTexture?
    var isBGRA: Bool { cbcrTexture == nil }
}

/// Converts `CVPixelBuffer` frames into reusable Metal textures using a cache.
/// After Effects-style layer-level caching: Texture cache is PERSISTENT and only
/// cleared selectively (track changes, large seeks), not on every frame update.
/// This prevents GPU thrashing during scrubbing and multi-layer compositing.
final class VideoFramePool {
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    // AFTER EFFECTS ARCHITECTURE: Per-clip texture cache with timestamp tracking
    // Key: (ClipID, QuantizedTimestamp) → Allows cache hits even with different CVPixelBuffer objects
    // CRITICAL FIX for scrubbing performance:
    // - DON'T include bufferID in cache key! AVAssetReader creates new CVPixelBuffer objects
    //   for each copyNextSampleBuffer() call, so bufferID changes even for same timestamp
    // - Quantize timestamp to MILLISECOND precision (not frame boundaries!)
    // - This allows cache hits when same CVPixelBuffer content is decoded multiple times
    //   but avoids conflating different video frames during scrubbing
    struct CacheKey: Hashable {
        let clipID: UUID
        let quantizedTimestamp: Int64  // Timestamp in milliseconds

        init(clipID: UUID, timestamp: TimeInterval) {
            self.clipID = clipID
            // Quantize to millisecond precision (1ms = 1000fps tolerance)
            // This provides cache hits for repeated MetalRenderer draws while maintaining
            // frame-accurate scrubbing (video frames are typically 16-41ms apart)
            if timestamp.isFinite {
                let quantized = (timestamp * 1000.0).rounded(.toNearestOrAwayFromZero)
                self.quantizedTimestamp = Int64(quantized)
            } else {
                self.quantizedTimestamp = 0
            }
        }
    }

    private var retainedTextures: [CacheKey: VideoTextures] = [:]
    private var lastAccessTime: [CacheKey: CFTimeInterval] = [:]
    private let maxCacheAge: TimeInterval = 5.0  // 5s cache lifetime
    private var lastCleanupTime: CFTimeInterval = CACurrentMediaTime()
    private let isLoggingEnabled = ProcessInfo.processInfo.environment["VIDEO_FRAME_POOL_DEBUG"] == "1"

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        guard isLoggingEnabled else { return }
        print(message())
    }

    func textures(for pixelBuffer: CVPixelBuffer, clipID: UUID, timestamp: TimeInterval, allowCache: Bool = true) -> VideoTextures? {
        guard let cache = textureCache else { return nil }
        let key = CacheKey(clipID: clipID, timestamp: timestamp)

        // AFTER EFFECTS LOGIC: Always use cache during scrubbing/playback
        // Only invalidate specific clips/timestamps, never clear globally
        if allowCache, let textures = retainedTextures[key] {
            lastAccessTime[key] = CACurrentMediaTime()
            debugLog("♻️ [VideoFramePool] CACHED texture for clip=\(clipID.uuidString.prefix(8)) @ \(String(format: "%.3f", timestamp))s (frame #\(key.quantizedTimestamp))")
            return textures
        }

        if !allowCache {
            debugLog("🆕 [VideoFramePool] allowCache=FALSE - creating NEW texture for clip=\(clipID.uuidString.prefix(8)) @ \(String(format: "%.3f", timestamp))s (frame #\(key.quantizedTimestamp))")
        } else {
            debugLog("🆕 [VideoFramePool] Creating NEW texture for clip=\(clipID.uuidString.prefix(8)) @ \(String(format: "%.3f", timestamp))s (frame #\(key.quantizedTimestamp), cache miss)")
        }

        // Periodic cleanup of old cache entries (After Effects memory management)
        cleanupOldCacheEntriesIfNeeded()

        // Check pixel format type
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // For YCbCr formats, we need both Y and CbCr planes
        let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil

        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {

            // Get the Y plane (plane 0)
            var cvTextureY: CVMetalTexture?
            let statusY = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                    cache,
                                                                    pixelBuffer,
                                                                    nil,
                                                                    .r8Unorm, // Y plane is single channel
                                                                    width,
                                                                    height,
                                                                    0, // plane index 0 = Y
                                                                    &cvTextureY)
            Task { @MainActor in
                ReverseScrubDiagnostics.shared.logMetalTexture(label: "VideoFramePool.Y",
                                                                status: statusY,
                                                                pixelFormat: pixelFormat,
                                                                planesOK: statusY == kCVReturnSuccess && cvTextureY != nil,
                                                                hasIOSurface: hasIOSurface)
            }
            guard statusY == kCVReturnSuccess,
                  let textureRefY = cvTextureY,
                  let yTexture = CVMetalTextureGetTexture(textureRefY) else {
                return nil
            }

            // Get the CbCr plane (plane 1)
            var cvTextureCbCr: CVMetalTexture?
            let statusCbCr = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                       cache,
                                                                       pixelBuffer,
                                                                       nil,
                                                                       .rg8Unorm, // CbCr plane is two channels
                                                                       width / 2,
                                                                       height / 2,
                                                                       1, // plane index 1 = CbCr
                                                                       &cvTextureCbCr)
            Task { @MainActor in
                ReverseScrubDiagnostics.shared.logMetalTexture(label: "VideoFramePool.CbCr",
                                                                status: statusCbCr,
                                                                pixelFormat: pixelFormat,
                                                                planesOK: statusCbCr == kCVReturnSuccess && cvTextureCbCr != nil,
                                                                hasIOSurface: hasIOSurface)
            }
            guard statusCbCr == kCVReturnSuccess,
                  let textureRefCbCr = cvTextureCbCr,
                  let cbcrTexture = CVMetalTextureGetTexture(textureRefCbCr) else {
                return nil
            }

            let textures = VideoTextures(yTexture: yTexture, cbcrTexture: cbcrTexture)
            if allowCache {
                retainedTextures[key] = textures
                lastAccessTime[key] = CACurrentMediaTime()
            }
            return textures
        }

        // For BGRA formats, use the original code
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               cache,
                                                               pixelBuffer,
                                                               nil,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &cvTexture)
        Task { @MainActor in
            ReverseScrubDiagnostics.shared.logMetalTexture(label: "VideoFramePool.BGRA",
                                                            status: status,
                                                            pixelFormat: pixelFormat,
                                                            planesOK: status == kCVReturnSuccess && cvTexture != nil,
                                                            hasIOSurface: hasIOSurface)
        }
        guard status == kCVReturnSuccess,
              let textureRef = cvTexture,
              let texture = CVMetalTextureGetTexture(textureRef) else {
            return nil
        }

        let textures = VideoTextures(yTexture: texture, cbcrTexture: nil)
        if allowCache {
            retainedTextures[key] = textures
            lastAccessTime[key] = CACurrentMediaTime()
        }
        return textures
    }

    // AFTER EFFECTS MEMORY MANAGEMENT: Selective cache cleanup
    private func cleanupOldCacheEntriesIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastCleanupTime > 1.0 else { return }  // Cleanup max once per second

        lastCleanupTime = now
        var keysToRemove: [CacheKey] = []

        for (key, lastAccess) in lastAccessTime {
            if now - lastAccess > maxCacheAge {
                keysToRemove.append(key)
            }
        }

        for key in keysToRemove {
            retainedTextures.removeValue(forKey: key)
            lastAccessTime.removeValue(forKey: key)
        }

        if !keysToRemove.isEmpty {
            debugLog("🧹 [VideoFramePool] Cleaned up \(keysToRemove.count) old cache entries (age > \(maxCacheAge)s)")
        }
    }

    // AFTER EFFECTS LOGIC: Selective invalidation (per-clip, not global!)
    func invalidateClip(_ clipID: UUID) {
        let keysToRemove = retainedTextures.keys.filter { $0.clipID == clipID }
        for key in keysToRemove {
            retainedTextures.removeValue(forKey: key)
            lastAccessTime.removeValue(forKey: key)
        }
        debugLog("🗑️ [VideoFramePool] Invalidated \(keysToRemove.count) textures for clip \(clipID.uuidString.prefix(8))")
    }

    // DEPRECATED: Don't use clear() during scrubbing! Use invalidateClip() instead
    // Only call clear() on track changes or project close
    func clear() {
        print("⚠️ [VideoFramePool] GLOBAL CLEAR - only use for track changes/project close!")
        retainedTextures.removeAll()
        lastAccessTime.removeAll()
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
