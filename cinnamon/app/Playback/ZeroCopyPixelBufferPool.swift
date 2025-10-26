import Foundation
import CoreVideo
import VideoToolbox
import Metal
import AVFoundation

/// Zero-Copy Pixel Buffer Pool with IOSurface backing for efficient VT→Metal pipeline
/// Implements Apple's best practices for unified memory on Apple Silicon
actor ZeroCopyPixelBufferPool {

    // MARK: - Types

    struct PoolConfig {
        let width: Int32
        let height: Int32
        let pixelFormat: OSType
        let minBufferCount: Int
        let maxBufferCount: Int
        let metalDevice: MTLDevice?

        static func defaultConfig(width: Int32, height: Int32, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> PoolConfig {
            return PoolConfig(
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                minBufferCount: 8,
                maxBufferCount: 32,
                metalDevice: MTLCreateSystemDefaultDevice()
            )
        }
    }

    private struct PoolKey: Hashable {
        let width: Int32
        let height: Int32
        let pixelFormat: OSType
    }

    // MARK: - Properties

    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private var metalTextureCache: CVMetalTextureCache?
    private let metalDevice: MTLDevice?
    private var activeBuffers: Set<CVPixelBuffer> = []
    private var bufferUsageCount: [CVPixelBuffer: Int] = [:]

    // Pool statistics for telemetry
    private var poolHits: Int = 0
    private var poolMisses: Int = 0
    private var allocationCount: Int = 0

    // MARK: - Initialization

    init(metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.metalDevice = metalDevice

        // Create Metal texture cache for zero-copy GPU access
        if let device = metalDevice {
            var cache: CVMetalTextureCache?
            let result = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil, // cache attributes
                device,
                nil, // texture attributes
                &cache
            )

            if result == kCVReturnSuccess {
                self.metalTextureCache = cache
                print("[ZeroCopyPool] CVMetalTextureCache created successfully")
            } else {
                print("[ZeroCopyPool] Failed to create CVMetalTextureCache: \(result)")
            }
        }
    }

    // MARK: - Public Methods

    /// Get a pixel buffer from the pool with zero-copy guarantees
    func getBuffer(width: Int32, height: Int32, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) async throws -> CVPixelBuffer {
        let key = PoolKey(width: width, height: height, pixelFormat: pixelFormat)

        // Get or create pool for this configuration
        let pool = try await getOrCreatePool(for: key)

        // Try to get buffer from pool
        var pixelBuffer: CVPixelBuffer?
        let auxAttributes: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 16 // Allow pool growth up to threshold
        ]

        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes as CFDictionary,
            &pixelBuffer
        )

        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            poolHits += 1
            activeBuffers.insert(buffer)
            bufferUsageCount[buffer] = 1
            return buffer
        } else {
            poolMisses += 1
            // Fallback: create standalone buffer with same attributes
            return try createStandaloneBuffer(width: width, height: height, pixelFormat: pixelFormat)
        }
    }

    /// Release a buffer back to the pool
    func releaseBuffer(_ buffer: CVPixelBuffer) async {
        activeBuffers.remove(buffer)
        if let count = bufferUsageCount[buffer], count > 1 {
            bufferUsageCount[buffer] = count - 1
        } else {
            bufferUsageCount.removeValue(forKey: buffer)
        }
    }

    /// Get a Metal texture from a pixel buffer (zero-copy on Apple Silicon)
    func getMetalTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int = 0) async -> MTLTexture? {
        guard let textureCache = metalTextureCache else {
            print("[ZeroCopyPool] No Metal texture cache available")
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        // Determine pixel format for the plane
        let pixelFormat: MTLPixelFormat = {
            let bufferFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            switch bufferFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                return planeIndex == 0 ? .r8Unorm : .rg8Unorm
            case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
                return planeIndex == 0 ? .r8Unorm : .rg8Unorm
            case kCVPixelFormatType_32BGRA:
                return .bgra8Unorm
            default:
                return .bgra8Unorm
            }
        }()

        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil, // texture attributes
            pixelFormat,
            width,
            height,
            planeIndex,
            &metalTexture
        )

        if status == kCVReturnSuccess, let texture = metalTexture {
            return CVMetalTextureGetTexture(texture)
        }

        print("[ZeroCopyPool] Failed to create Metal texture: \(status)")
        return nil
    }

    /// Flush unused buffers and compact pools
    func flush() async {
        for (key, pool) in pools {
            CVPixelBufferPoolFlush(pool, CVPixelBufferPoolFlushFlags.excessBuffers)
        }

        // Clear inactive buffers
        activeBuffers = activeBuffers.filter { buffer in
            bufferUsageCount[buffer] != nil && bufferUsageCount[buffer]! > 0
        }

        if let textureCache = metalTextureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }

        print("[ZeroCopyPool] Flushed pools - Active buffers: \(activeBuffers.count)")
    }

    /// Get pool statistics for telemetry
    func getStatistics() -> (hits: Int, misses: Int, allocations: Int, activeBuffers: Int) {
        return (poolHits, poolMisses, allocationCount, activeBuffers.count)
    }

    // MARK: - Private Methods

    private func getOrCreatePool(for key: PoolKey) async throws -> CVPixelBufferPool {
        if let existingPool = pools[key] {
            return existingPool
        }

        // Create pool attributes with IOSurface backing for zero-copy
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 8,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 1.0 // Recycle after 1 second
        ]

        // CRITICAL: IOSurface backing enables zero-copy between VT and Metal
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: key.width,
            kCVPixelBufferHeightKey as String: key.height,
            kCVPixelBufferPixelFormatTypeKey as String: key.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any], // Enable IOSurface
            kCVPixelBufferMetalCompatibilityKey as String: true, // Metal compatibility
            // Memory alignment for optimal performance
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            // Optimize for GPU access on Apple Silicon
            kCVPixelBufferCGImageCompatibilityKey as String: false,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: false
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        guard status == kCVReturnSuccess, let createdPool = pool else {
            throw NSError(domain: "ZeroCopyPixelBufferPool",
                         code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer pool"])
        }

        pools[key] = createdPool
        print("[ZeroCopyPool] Created pool for \(key.width)x\(key.height) format:\(fourCCString(key.pixelFormat))")

        return createdPool
    }

    private func createStandaloneBuffer(width: Int32, height: Int32, pixelFormat: OSType) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "ZeroCopyPixelBufferPool",
                         code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create standalone pixel buffer"])
        }

        allocationCount += 1
        activeBuffers.insert(buffer)
        bufferUsageCount[buffer] = 1

        return buffer
    }

    private func fourCCString(_ fourCC: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((fourCC >> 24) & 0xFF),
            UInt8((fourCC >> 16) & 0xFF),
            UInt8((fourCC >> 8) & 0xFF),
            UInt8(fourCC & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// MARK: - Global Singleton Instance

extension ZeroCopyPixelBufferPool {
    static let shared = ZeroCopyPixelBufferPool()
}