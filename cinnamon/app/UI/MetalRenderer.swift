import Foundation
import MetalKit
import CoreGraphics
import simd

final class MetalRenderer: NSObject, MTKViewDelegate {
    private struct VertexUniforms {
        var modelToNDC: simd_float4x4
        var mediaSize: SIMD2<Float>
    }

    private struct FragmentUniforms {
        var opacity: Float
        var blendMode: UInt32
        var matteMode: UInt32
        var isYCbCr: UInt32 = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexUniforms {
        float4x4 modelToNDC;
        float2 mediaSize;
    };

    struct FragmentUniforms {
        float opacity;
        uint blendMode;
        uint matteMode;
        uint isYCbCr;  // 1 if source is YCbCr, 0 if BGRA
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    constant float kEpsilon = 1e-5;

    constant uint BlendNormal = 0;
    constant uint BlendMultiply = 1;
    constant uint BlendScreen = 2;
    constant uint BlendOverlay = 3;
    constant uint BlendSoftLight = 4;
    constant uint BlendHardLight = 5;
    constant uint BlendColorDodge = 6;
    constant uint BlendColorBurn = 7;
    constant uint BlendDarken = 8;
    constant uint BlendLighten = 9;
    constant uint BlendDifference = 10;
    constant uint BlendExclusion = 11;

    constant uint MatteNone = 0;
    constant uint MatteAlpha = 1;
    constant uint MatteAlphaInverted = 2;
    constant uint MatteLuma = 3;
    constant uint MatteLumaInverted = 4;

    inline float3 overlayBlend(float3 src, float3 dst) {
        return mix(2.0 * dst * src,
                   1.0 - 2.0 * (1.0 - dst) * (1.0 - src),
                   step(float3(0.5), dst));
    }

    inline float3 softLightBlend(float3 src, float3 dst) {
        float3 low = dst - (1.0 - 2.0 * src) * dst * (1.0 - dst);
        float3 high = dst + (2.0 * src - 1.0) * (sqrt(dst) - dst);
        return mix(low, high, step(float3(0.5), src));
    }

    inline float3 hardLightBlend(float3 src, float3 dst) {
        return overlayBlend(dst, src);
    }

    inline float3 applyBlend(uint mode, float3 src, float3 dst) {
        switch (mode) {
            case BlendMultiply:
                return dst * src;
            case BlendScreen:
                return 1.0 - (1.0 - dst) * (1.0 - src);
            case BlendOverlay:
                return overlayBlend(src, dst);
            case BlendSoftLight:
                return softLightBlend(src, dst);
            case BlendHardLight:
                return hardLightBlend(src, dst);
            case BlendColorDodge:
                return min(dst / max(1.0 - src, float3(kEpsilon)), 1.0);
            case BlendColorBurn:
                return 1.0 - min((1.0 - dst) / max(src, float3(kEpsilon)), 1.0);
            case BlendDarken:
                return min(dst, src);
            case BlendLighten:
                return max(dst, src);
            case BlendDifference:
                return abs(dst - src);
            case BlendExclusion:
                return dst + src - 2.0 * dst * src;
            default:
                return src;
        }
    }

    vertex VertexOut vertex_passthrough(uint vertexID [[vertex_id]],
                                        constant VertexUniforms &uniforms [[buffer(0)]]) {
        constexpr float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        constexpr float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };

        VertexOut outVertex;
        float2 corners[4] = {
            float2(0.0, uniforms.mediaSize.y),
            float2(uniforms.mediaSize.x, uniforms.mediaSize.y),
            float2(0.0, 0.0),
            float2(uniforms.mediaSize.x, 0.0)
        };

        float4 transformed = uniforms.modelToNDC * float4(corners[vertexID], 0.0, 1.0);
        outVertex.position = transformed;
        outVertex.texCoord = uvs[vertexID];
        return outVertex;
    }

    fragment float4 fragment_textured(VertexOut in [[stage_in]],
                                      constant FragmentUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> sourceTexture [[texture(0)]],
                                      texture2d<float> backgroundTexture [[texture(1)]],
                                      texture2d<float> matteTexture [[texture(2)]],
                                      texture2d<float> cbcrTexture [[texture(3)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

        float4 src = float4(0.0);
        if (!is_null_texture(sourceTexture)) {
            if (uniforms.isYCbCr == 1 && !is_null_texture(cbcrTexture)) {
                // YCbCr to RGB conversion
                float y = sourceTexture.sample(textureSampler, in.texCoord).r;
                float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;

                // ITU-R BT.601 conversion matrix
                float cb = cbcr.x - 0.5;
                float cr = cbcr.y - 0.5;

                float r = y + 1.402 * cr;
                float g = y - 0.344136 * cb - 0.714136 * cr;
                float b = y + 1.772 * cb;

                src = float4(r, g, b, 1.0);
            } else {
                src = sourceTexture.sample(textureSampler, in.texCoord);
            }
        }
        float4 dst = float4(0.0);
        if (!is_null_texture(backgroundTexture)) {
            dst = backgroundTexture.sample(textureSampler, in.texCoord);
        }

        float matte = 1.0;
        if (uniforms.matteMode != MatteNone && !is_null_texture(matteTexture)) {
            float4 matteSample = matteTexture.sample(textureSampler, in.texCoord);
            float luminance = dot(matteSample.rgb, float3(0.299, 0.587, 0.114));
            switch (uniforms.matteMode) {
                case MatteAlpha:
                    matte = matteSample.a;
                    break;
                case MatteAlphaInverted:
                    matte = 1.0 - matteSample.a;
                    break;
                case MatteLuma:
                    matte = luminance;
                    break;
                case MatteLumaInverted:
                    matte = 1.0 - luminance;
                    break;
                default:
                    matte = 1.0;
                    break;
            }
            matte = clamp(matte, 0.0, 1.0);
        }

        float alpha = clamp(src.a * uniforms.opacity, 0.0, 1.0) * matte;
        float3 srcColor = alpha > kEpsilon ? src.rgb / max(alpha, kEpsilon) : float3(0.0);
        float3 blended = applyBlend(uniforms.blendMode, srcColor, dst.rgb);

        float3 outColor = dst.rgb * (1.0 - alpha) + blended * alpha;
        float outAlpha = alpha + dst.a * (1.0 - alpha);
        return float4(clamp(outColor, 0.0, 1.0), clamp(outAlpha, 0.0, 1.0));
    }
    """

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let compositePipelineState: MTLRenderPipelineState
    private let framePool: VideoFramePool
    private let transport = TransportController.shared
    private var compositeTextures: [MTLTexture?] = [nil, nil]
    private var compositeSize: (width: Int, height: Int) = (0, 0)
    private var lastRenderedFrameNumber: Int = -1
    private var matteTexture: MTLTexture?
    private let clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
    private var lastReportedSize = CGSize.zero
    private weak var mtkView: MTKView?
    private var hasRenderedInitialFrame = false
    private var pendingRects: [CGRect] = []
    private let supportsParallelEncoding: Bool
    // AFTER EFFECTS LOGIC: Always cache textures (managed by VideoFramePool per-clip)

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.framePool = VideoFramePool(device: device)
        if #available(macOS 11.0, *) {
            self.supportsParallelEncoding = true
        } else {
            self.supportsParallelEncoding = false
        }
        self.mtkView = mtkView

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        // Will be updated dynamically based on composition framerate
        mtkView.preferredFramesPerSecond = 60 // Default, will be updated

        do {
            let library = try device.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_passthrough")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_textured")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
            compositePipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }

        super.init()
        mtkView.delegate = self

        // AFTER EFFECTS LOGIC: No global cache clearing on frame updates!
        // Texture cache is persistent and managed per-clip with automatic cleanup
        // This prevents GPU thrashing during scrubbing and multi-layer compositing
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Notify about canvas size change
        NotificationCenter.default.post(name: Notification.Name("CanvasSizeChanged"),
                                       object: nil,
                                       userInfo: ["size": size])
    }

    /// Update MTKView framerate for optimal playback
    func updateFrameRate(for compositionFrameRate: Double) {
        // DISPLAY-SYNC: Always use 60Hz for smooth playback
        // Composition framerate is only relevant for export, not preview
        let displaySyncRate = 60
        mtkView?.preferredFramesPerSecond = displaySyncRate
        print("[MetalRenderer] ✅ Display-Sync @ \(displaySyncRate)fps " +
              "(composition: \(compositionFrameRate)fps for export only)")
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            // DISPLAY-SYNC: Always render at display refresh rate (60Hz) during playback
            // This matches TimelineTicker's 60Hz tick rate for smooth, jitter-free playback
            // Frame selection uses NEAREST-PREVIOUS based on video PTS, not composition rate
            let playbackState = transport.playbackState
            if playbackState == .paused {
                // Paused: Render at much lower rate (10fps) to save resources
                // Still need some rendering for UI updates (e.g., timeline cursor)
                if view.preferredFramesPerSecond != 10 {
                    view.preferredFramesPerSecond = 10
                }
            } else {
                // Playing or scrubbing: Render at display refresh rate (60Hz)
                // NOT composition framerate - that's only for export!
                if view.preferredFramesPerSecond != 60 {
                    view.preferredFramesPerSecond = 60
                }
            }

            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            let drawableSize = view.drawableSize

            // Report canvas size on first draw and when changed
            if drawableSize != lastReportedSize && drawableSize.width > 0 && drawableSize.height > 0 {
                lastReportedSize = drawableSize
                NotificationCenter.default.post(name: Notification.Name("CanvasSizeChanged"),
                                               object: nil,
                                               userInfo: ["size": drawableSize])
            }

            guard ensureCompositeTextures(for: drawableSize) else { return }
            guard let baseTexture = compositeTextures[0],
                  let secondaryTexture = compositeTextures[1] else { return }

            var dirtyRects = transport.consumeDirtyRects()
            if playbackState == .playing || dirtyRects.isEmpty {
                dirtyRects = [CGRect(origin: .zero, size: drawableSize)]
            }

            let dirtyUnion = union(of: dirtyRects, fallback: CGRect(origin: .zero, size: drawableSize))
            let coversFullCanvas = rect(dirtyUnion, covers: drawableSize)
            let shouldClear = !hasRenderedInitialFrame || playbackState == .playing || coversFullCanvas
            let firstPassLoadAction: MTLLoadAction = shouldClear ? .clear : .load

            if shouldClear {
                clear(texture: baseTexture, with: commandBuffer)
                hasRenderedInitialFrame = true
            } else {
                blitCopy(source: baseTexture, destination: secondaryTexture, commandBuffer: commandBuffer)
            }

            pendingRects = dirtyRects

            let tileCount = dirtyRects.count
            let unionArea = Double(dirtyUnion.width * dirtyUnion.height)
            let canvasArea = Double(drawableSize.width * drawableSize.height)
            let coverage = canvasArea > 0 ? min(max(unionArea / canvasArea, 0.0), 1.0) : (tileCount > 0 ? 1.0 : 0.0)

            ScrubTelemetry.shared.logRenderTiles(ScrubTelemetry.TileRenderLog(
                timestamp: CFAbsoluteTimeGetCurrent(),
                dirtyTileCount: tileCount,
                coverage: coverage,
                fullFrame: coversFullCanvas
            ))

            let useParallelTiles = supportsParallelEncoding && dirtyRects.count > 1 && !coversFullCanvas

            var readTexture: MTLTexture = baseTexture
            var writeTexture: MTLTexture = secondaryTexture

            // CRITICAL FIX: Use correct time source based on playback state
            // During playback we use the master PlaybackClock; during scrubbing we rely on the latched transport time.
            let time: TimeInterval
            if playbackState == .playing {
                time = PlaybackClock.shared.currentTime()
            } else {
                time = transport.latchedTime
            }

            // DEBUG: Log periodically to confirm the renderer stays active under load.
            lastRenderedFrameNumber += 1
            if lastRenderedFrameNumber % 20 == 0 {
                print("[MetalRenderer] draw() #\(lastRenderedFrameNumber) at time=\(String(format: "%.3f", time))s (state=\(playbackState))")
            }

            // Always render, but drive content selection from the frame-accurate timebase.
            let timebase = transport.frameTimebase
            _ = timebase.frameIndex(for: time, rounding: .nearest)

            guard let slice = transport.compositeSlice(at: time) else {
                copy(texture: readTexture, to: drawable.texture, commandBuffer: commandBuffer)
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            let matteAssignments = slice.mattes
            let orderedSegments = slice.orderedSegments.reversed()
            let canvasSizeVec = SIMD2<Float>(Float(compositeSize.width), Float(compositeSize.height))
            let canvasCGSize = CGSize(width: CGFloat(compositeSize.width), height: CGFloat(compositeSize.height))

            for (segmentIndex, segment) in orderedSegments.enumerated() {
                guard let clip = segment.clip else { continue }

                guard let buffer = transport.pixelBufferSync(for: clip.id, at: time) else {
                    continue
                }

                guard let videoTextures = framePool.textures(for: buffer, clipID: clip.id, timestamp: time, allowCache: true) else {
                    print("[MetalRenderer] Could not create texture from buffer")
                    continue
                }

                let sourceTexture = videoTextures.yTexture
                let cbcrTexture = videoTextures.cbcrTexture
                let isYCbCr = !videoTextures.isBGRA

                let mediaSize = SIMD2<Float>(Float(sourceTexture.width), Float(sourceTexture.height))
                let transformMatrix = modelMatrix(for: clip,
                                                  mediaSize: mediaSize,
                                                  canvasSize: canvasSizeVec)

                var matteTexture: MTLTexture?
                var matteMode = segment.matteMode
                if let attachment = matteAssignments[clip.id], matteMode != .none {
                    if let matteBuffer = transport.pixelBufferSync(for: attachment.clip.id, at: time),
                       let matteVideoTextures = framePool.textures(for: matteBuffer, clipID: attachment.clip.id, timestamp: time, allowCache: true),
                       let renderedMatte = renderMatte(commandBuffer: commandBuffer,
                                                       attachment: attachment,
                                                       sourceTexture: matteVideoTextures.yTexture,
                                                       cbcrTexture: matteVideoTextures.cbcrTexture,
                                                       canvasSize: canvasSizeVec,
                                                       canvasCGSize: canvasCGSize,
                                                       isYCbCr: !matteVideoTextures.isBGRA) {
                        matteTexture = renderedMatte
                        matteMode = attachment.mode
                    } else {
                        matteMode = .none
                    }
                } else {
                    matteMode = .none
                }

                let clipRect = boundingRect(for: clip,
                                            mediaSize: CGSize(width: CGFloat(sourceTexture.width),
                                                              height: CGFloat(sourceTexture.height)),
                                            canvasSize: canvasCGSize)
                if !shouldClear && clipRect?.intersects(dirtyUnion) == false {
                    continue
                }

                let effectiveRect: CGRect? = {
                    guard let rect = clipRect else { return shouldClear ? nil : dirtyUnion }
                    let intersection = rect.intersection(dirtyUnion)
                    return intersection.isNull ? nil : intersection
                }()

                if !shouldClear && effectiveRect == nil {
                    continue
                }

                let targetRect = effectiveRect ?? dirtyUnion
                if targetRect.width <= 0 || targetRect.height <= 0 {
                    continue
                }

                let loadAction = segmentIndex == 0 ? firstPassLoadAction : .load

                if useParallelTiles {
                    let parallelScissors = dirtyRects.compactMap { rect -> MTLScissorRect? in
                        let intersection = rect.intersection(targetRect)
                        guard intersection.width > 0, intersection.height > 0 else { return nil }
                        return scissorRect(for: intersection, texture: writeTexture)
                    }

                    if !parallelScissors.isEmpty {
                        encodeCompositeParallel(commandBuffer: commandBuffer,
                                                destination: writeTexture,
                                                background: readTexture,
                                                source: sourceTexture,
                                                cbcrTexture: cbcrTexture,
                                                transform: transformMatrix,
                                                mediaSize: mediaSize,
                                                blendMode: segment.blendMode,
                                                opacity: segment.opacity,
                                                matteTexture: matteTexture,
                                                matteMode: matteMode,
                                                isYCbCr: isYCbCr,
                                                loadAction: loadAction,
                                                scissorRects: parallelScissors)
                    } else {
                        let scissor = scissorRect(for: targetRect, texture: writeTexture)
                        encodeComposite(commandBuffer: commandBuffer,
                                         destination: writeTexture,
                                         background: readTexture,
                                         source: sourceTexture,
                                         cbcrTexture: cbcrTexture,
                                         transform: transformMatrix,
                                         mediaSize: mediaSize,
                                         blendMode: segment.blendMode,
                                         opacity: segment.opacity,
                                         matteTexture: matteTexture,
                                         matteMode: matteMode,
                                         isYCbCr: isYCbCr,
                                         loadAction: loadAction,
                                         scissorRect: scissor)
                    }
                } else {
                    let scissor = scissorRect(for: targetRect, texture: writeTexture)
                    encodeComposite(commandBuffer: commandBuffer,
                                     destination: writeTexture,
                                     background: readTexture,
                                     source: sourceTexture,
                                     cbcrTexture: cbcrTexture,
                                     transform: transformMatrix,
                                     mediaSize: mediaSize,
                                     blendMode: segment.blendMode,
                                     opacity: segment.opacity,
                                     matteTexture: matteTexture,
                                     matteMode: matteMode,
                                     isYCbCr: isYCbCr,
                                     loadAction: loadAction,
                                     scissorRect: scissor)
                }

                swap(&readTexture, &writeTexture)
            }

            copy(texture: readTexture, to: drawable.texture, commandBuffer: commandBuffer)

            commandBuffer.present(drawable)
            commandBuffer.commit()
            // AFTER EFFECTS LOGIC: No framePool.clear()! Cache is persistent and auto-cleaned
            // Only call clear() on track changes or project close

            compositeTextures[0] = readTexture
            compositeTextures[1] = writeTexture
        }
    }

    private func ensureCompositeTextures(for size: CGSize) -> Bool {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if compositeSize.width == width && compositeSize.height == height,
           compositeTextures[0] != nil, compositeTextures[1] != nil {
            return true
        }

        compositeSize = (width, height)
        compositeTextures[0] = makeCompositeTexture(width: width, height: height)
        compositeTextures[1] = makeCompositeTexture(width: width, height: height)
        matteTexture = nil
        hasRenderedInitialFrame = false
        return compositeTextures[0] != nil && compositeTextures[1] != nil
    }

    private func makeCompositeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func ensureMatteTexture(for size: CGSize) -> MTLTexture? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if let matte = matteTexture,
           matte.width == width,
           matte.height == height {
            return matte
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        matteTexture = device.makeTexture(descriptor: descriptor)
        return matteTexture
    }

    private func clear(texture: MTLTexture, with commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
    }

    private func makeCompositePassDescriptor(destination: MTLTexture,
                                             loadAction: MTLLoadAction) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        return descriptor
    }

    private func encodeComposite(commandBuffer: MTLCommandBuffer,
                                 destination: MTLTexture,
                                 background: MTLTexture?,
                                 source: MTLTexture,
                                 cbcrTexture: MTLTexture? = nil,
                                 transform: simd_float4x4,
                                 mediaSize: SIMD2<Float>,
                                 blendMode: BlendMode,
                                 opacity: Float,
                                 matteTexture: MTLTexture? = nil,
                                 matteMode: TrackMatteMode = .none,
                                 isYCbCr: Bool = false,
                                 loadAction: MTLLoadAction = .dontCare,
                                 scissorRect: MTLScissorRect? = nil) {
        let descriptor = makeCompositePassDescriptor(destination: destination, loadAction: loadAction)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        applyCompositeState(encoder: encoder,
                            destination: destination,
                            background: background,
                            source: source,
                            cbcrTexture: cbcrTexture,
                            transform: transform,
                            mediaSize: mediaSize,
                            blendMode: blendMode,
                            opacity: opacity,
                            matteTexture: matteTexture,
                            matteMode: matteMode,
                            isYCbCr: isYCbCr,
                            scissorRect: scissorRect)

        encoder.endEncoding()
    }

    private func encodeCompositeParallel(commandBuffer: MTLCommandBuffer,
                                         destination: MTLTexture,
                                         background: MTLTexture?,
                                         source: MTLTexture,
                                         cbcrTexture: MTLTexture? = nil,
                                         transform: simd_float4x4,
                                         mediaSize: SIMD2<Float>,
                                         blendMode: BlendMode,
                                         opacity: Float,
                                         matteTexture: MTLTexture? = nil,
                                         matteMode: TrackMatteMode = .none,
                                         isYCbCr: Bool = false,
                                         loadAction: MTLLoadAction = .dontCare,
                                         scissorRects: [MTLScissorRect]) {
        guard !scissorRects.isEmpty else { return }

        let descriptor = makeCompositePassDescriptor(destination: destination, loadAction: loadAction)
        if let parallelEncoder = commandBuffer.makeParallelRenderCommandEncoder(descriptor: descriptor) {
            for scissor in scissorRects {
                guard let encoder = parallelEncoder.makeRenderCommandEncoder() else { continue }
                applyCompositeState(encoder: encoder,
                                    destination: destination,
                                    background: background,
                                    source: source,
                                    cbcrTexture: cbcrTexture,
                                    transform: transform,
                                    mediaSize: mediaSize,
                                    blendMode: blendMode,
                                    opacity: opacity,
                                    matteTexture: matteTexture,
                                    matteMode: matteMode,
                                    isYCbCr: isYCbCr,
                                    scissorRect: scissor)
                encoder.endEncoding()
            }
            parallelEncoder.endEncoding()
            return
        }

        var fallbackLoadAction = loadAction
        for scissor in scissorRects {
            encodeComposite(commandBuffer: commandBuffer,
                             destination: destination,
                             background: background,
                             source: source,
                             cbcrTexture: cbcrTexture,
                             transform: transform,
                             mediaSize: mediaSize,
                             blendMode: blendMode,
                             opacity: opacity,
                             matteTexture: matteTexture,
                             matteMode: matteMode,
                             isYCbCr: isYCbCr,
                             loadAction: fallbackLoadAction,
                             scissorRect: scissor)
            fallbackLoadAction = .load
        }
    }

    private func applyCompositeState(encoder: MTLRenderCommandEncoder,
                                     destination: MTLTexture,
                                     background: MTLTexture?,
                                     source: MTLTexture,
                                     cbcrTexture: MTLTexture?,
                                     transform: simd_float4x4,
                                     mediaSize: SIMD2<Float>,
                                     blendMode: BlendMode,
                                     opacity: Float,
                                     matteTexture: MTLTexture?,
                                     matteMode: TrackMatteMode,
                                     isYCbCr: Bool,
                                     scissorRect: MTLScissorRect?) {
        encoder.setRenderPipelineState(compositePipelineState)

        if let scissorRect = scissorRect {
            encoder.setScissorRect(scissorRect)
        } else {
            encoder.setScissorRect(fullScissorRect(for: destination))
        }

        var vertexUniforms = VertexUniforms(modelToNDC: transform,
                                            mediaSize: mediaSize)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)

        var fragmentUniforms = FragmentUniforms(opacity: opacity,
                                                blendMode: blendIdentifier(for: blendMode),
                                                matteMode: matteModeIdentifier(for: matteMode),
                                                isYCbCr: isYCbCr ? 1 : 0)
        encoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(background, index: 1)
        encoder.setFragmentTexture(matteTexture, index: 2)
        encoder.setFragmentTexture(cbcrTexture, index: 3)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func fullScissorRect(for texture: MTLTexture) -> MTLScissorRect {
        MTLScissorRect(x: 0, y: 0, width: texture.width, height: texture.height)
    }

    private func copy(texture: MTLTexture, to drawableTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        // Always use render pass - more reliable than blit for different texture formats
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawableTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(compositePipelineState)

        let mediaSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
        let canvasSize = SIMD2<Float>(Float(drawableTexture.width), Float(drawableTexture.height))
        let transform = fullScreenMatrix(mediaSize: mediaSize, canvasSize: canvasSize)

        var vertexUniforms = VertexUniforms(modelToNDC: transform,
                                            mediaSize: mediaSize)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)

        var fragmentUniforms = FragmentUniforms(opacity: 1.0,
                                               blendMode: blendIdentifier(for: .normal),
                                               matteMode: 0,
                                               isYCbCr: 0)
        encoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.stride, index: 0)

        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(nil, index: 1)
        encoder.setFragmentTexture(nil, index: 2)
        encoder.setFragmentTexture(nil, index: 3)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func blitCopy(source: MTLTexture, destination: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.copy(from: source,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: source.width, height: source.height, depth: source.depth),
                         to: destination,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
    }

    private func union(of rects: [CGRect], fallback: CGRect) -> CGRect {
        guard var result = rects.first else { return fallback }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private func rect(_ rect: CGRect, covers canvas: CGSize) -> Bool {
        guard canvas.width > 0, canvas.height > 0 else { return true }
        let expanded = rect.insetBy(dx: -1, dy: -1)
        return expanded.minX <= 0 && expanded.minY <= 0 &&
               expanded.maxX >= canvas.width && expanded.maxY >= canvas.height
    }

    private func scissorRect(for rect: CGRect, texture: MTLTexture) -> MTLScissorRect {
        let width = texture.width
        let height = texture.height

        let minX = max(0, Int(floor(rect.minX)))
        let maxX = min(width, Int(ceil(rect.maxX)))
        let minYCanvas = max(0, Int(floor(rect.minY)))
        let maxYCanvas = min(height, Int(ceil(rect.maxY)))

        let clampedMinX = min(minX, width)
        let clampedMaxX = max(clampedMinX, maxX)
        let clampedMinY = min(minYCanvas, height)
        let clampedMaxY = max(clampedMinY, maxYCanvas)

        let scissorX = clampedMinX
        let scissorY = max(0, height - clampedMaxY)
        let scissorWidth = max(1, clampedMaxX - clampedMinX)
        let scissorHeight = max(1, clampedMaxY - clampedMinY)

        return MTLScissorRect(x: scissorX,
                              y: scissorY,
                              width: min(scissorWidth, width),
                              height: min(scissorHeight, height))
    }

    private func boundingRect(for clip: Clip,
                              mediaSize: CGSize,
                              canvasSize: CGSize) -> CGRect? {
        guard clip.transform.opacity > 0.01 else { return nil }
        let width = mediaSize.width
        let height = mediaSize.height
        guard width > 0, height > 0 else { return nil }

        let anchor = CGPoint(x: CGFloat(clip.transform.anchor.x) * width,
                             y: CGFloat(clip.transform.anchor.y) * height)
        let position = CGPoint(x: CGFloat(clip.transform.position.x),
                               y: CGFloat(clip.transform.position.y))

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: -anchor.x, y: -anchor.y)
        transform = transform.scaledBy(x: CGFloat(clip.transform.scale.x), y: CGFloat(clip.transform.scale.y))
        transform = transform.rotated(by: CGFloat(clip.transform.rotation))
        transform = transform.translatedBy(x: position.x, y: position.y)

        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: 0, y: height)
        ].map { $0.applying(transform) }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in corners {
            guard point.x.isFinite, point.y.isFinite else { return nil }
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        let rect = CGRect(x: minX,
                          y: minY,
                          width: maxX - minX,
                          height: maxY - minY)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let clipped = rect.intersection(canvasRect)
        return clipped.isNull ? nil : clipped
    }

    private func matteModeIdentifier(for mode: TrackMatteMode) -> UInt32 {
        switch mode {
        case .none: return 0
        case .alpha: return 1
        case .alphaInverted: return 2
        case .luma: return 3
        case .lumaInverted: return 4
        }
    }

    private func blendIdentifier(for mode: BlendMode) -> UInt32 {
        switch mode {
        case .normal:
            return 0
        case .multiply:
            return 1
        case .screen:
            return 2
        case .overlay:
            return 3
        case .softLight:
            return 4
        case .hardLight:
            return 5
        case .colorDodge:
            return 6
        case .colorBurn:
            return 7
        case .darken:
            return 8
        case .lighten:
            return 9
        case .difference:
            return 10
        case .exclusion:
            return 11
        }
    }

    private func modelMatrix(for clip: Clip,
                             mediaSize: SIMD2<Float>,
                             canvasSize: SIMD2<Float>) -> simd_float4x4 {
        TransformMath.modelToNDC(transform: clip.transform,
                                  mediaSize: mediaSize,
                                  canvasSize: canvasSize)
    }

    private func fullScreenMatrix(mediaSize: SIMD2<Float>,
                                  canvasSize: SIMD2<Float>) -> simd_float4x4 {
        var transform = Transform2D()
        transform.position = SIMD2<Float>(canvasSize.x * 0.5, canvasSize.y * 0.5)
        return TransformMath.modelToNDC(transform: transform,
                                        mediaSize: mediaSize,
                                        canvasSize: canvasSize)
    }

    private func renderMatte(commandBuffer: MTLCommandBuffer,
                             attachment: TimelineMatteAttachment,
                             sourceTexture: MTLTexture,
                             cbcrTexture: MTLTexture? = nil,
                             canvasSize: SIMD2<Float>,
                             canvasCGSize: CGSize,
                             isYCbCr: Bool = false) -> MTLTexture? {
        guard let matteTarget = ensureMatteTexture(for: canvasCGSize) else { return nil }
        clear(texture: matteTarget, with: commandBuffer)

        let mediaSize = SIMD2<Float>(Float(sourceTexture.width), Float(sourceTexture.height))
        let transform = modelMatrix(for: attachment.clip,
                                    mediaSize: mediaSize,
                                    canvasSize: canvasSize)

        encodeComposite(commandBuffer: commandBuffer,
                         destination: matteTarget,
                         background: nil,
                         source: sourceTexture,
                         cbcrTexture: cbcrTexture,
                         transform: transform,
                         mediaSize: mediaSize,
                         blendMode: .normal,
                         opacity: 1.0,
                         matteTexture: nil,
                         matteMode: .none,
                         isYCbCr: isYCbCr,
                         loadAction: .dontCare,
                         scissorRect: nil)
        return matteTarget
    }
}
