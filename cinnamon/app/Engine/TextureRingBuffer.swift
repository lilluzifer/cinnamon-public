import CoreMedia
import CoreVideo
import IOSurface
import Metal

/// Fixed-size ring buffer that stores the latest pixel buffers and their pre-baked Metal textures.
struct TextureRingBuffer {
    struct Slot {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let lumaTexture: MTLTexture?
        let chromaTexture: MTLTexture?
    }

    private var slots: [Slot] = []
    private let capacity: Int
    private var textureCache: CVMetalTextureCache?

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    mutating func configureCache(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    mutating func reset() {
        slots.removeAll(keepingCapacity: true)
    }

    mutating func append(pixelBuffer: CVPixelBuffer, time: CMTime) {
        let textures = makeTextures(from: pixelBuffer)
        let slot = Slot(pixelBuffer: pixelBuffer,
                       presentationTime: time,
                       lumaTexture: textures.luma,
                       chromaTexture: textures.chroma)
        slots.append(slot)
        if slots.count > capacity {
            slots.removeFirst(slots.count - capacity)
        }
    }

    mutating func consumeLatched() -> Slot? {
        guard let slot = slots.last else { return nil }
        slots.removeAll(keepingCapacity: true)
        slots.append(slot)
        return slot
    }

    var latchedSlot: Slot? {
        slots.last
    }

    private mutating func makeTextures(from pixelBuffer: CVPixelBuffer) -> (luma: MTLTexture?, chroma: MTLTexture?) {
        guard let cache = textureCache else { return (nil, nil) }

        var lumaTextureRef: CVMetalTexture?
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(nil,
                                                                   cache,
                                                                   pixelBuffer,
                                                                   nil,
                                                                   .r8Unorm,
                                                                   lumaWidth,
                                                                   lumaHeight,
                                                                   0,
                                                                   &lumaTextureRef)
        Task { @MainActor in
            ReverseScrubDiagnostics.shared.logMetalTexture(label: "TextureRing.Luma",
                                                            status: lumaStatus,
                                                            pixelFormat: pixelFormat,
                                                            planesOK: lumaStatus == kCVReturnSuccess && lumaTextureRef != nil,
                                                            hasIOSurface: hasIOSurface)
        }

        var chromaTextureRef: CVMetalTexture?
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(nil,
                                                                     cache,
                                                                     pixelBuffer,
                                                                     nil,
                                                                     .rg8Unorm,
                                                                     chromaWidth,
                                                                     chromaHeight,
                                                                     1,
                                                                     &chromaTextureRef)
        Task { @MainActor in
            ReverseScrubDiagnostics.shared.logMetalTexture(label: "TextureRing.Chroma",
                                                            status: chromaStatus,
                                                            pixelFormat: pixelFormat,
                                                            planesOK: chromaStatus == kCVReturnSuccess && chromaTextureRef != nil,
                                                            hasIOSurface: hasIOSurface)
        }

        guard lumaStatus == kCVReturnSuccess,
              chromaStatus == kCVReturnSuccess,
              let lumaTextureRef,
              let chromaTextureRef,
              let lumaTexture = CVMetalTextureGetTexture(lumaTextureRef),
              let chromaTexture = CVMetalTextureGetTexture(chromaTextureRef) else {
            CVMetalTextureCacheFlush(cache, 0)
            return (nil, nil)
        }

        return (lumaTexture, chromaTexture)
    }
}
