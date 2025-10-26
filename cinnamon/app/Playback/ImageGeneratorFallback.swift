import AVFoundation
import CoreVideo
import CoreGraphics

/// Managed ImageGenerator fallback with hysteresis and telemetry
actor ImageGeneratorFallback {
    
    // MARK: - Types
    
    struct FallbackMetrics {
        var activations: Int = 0
        var deactivations: Int = 0
        var framesDecoded: Int = 0
        var avgDecodeTimeMS: Double = 0
        var lastActivationTime: CFAbsoluteTime = 0
        var lastDeactivationTime: CFAbsoluteTime = 0
    }
    
    enum FallbackState {
        case inactive
        case active(since: CFAbsoluteTime, reason: String)
    }
    
    // MARK: - Properties
    
    private let clipID: UUID
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let config: ScrubFeatureFlags.Config
    
    private var generator: AVAssetImageGenerator?
    private var state: FallbackState = .inactive
    private var metrics = FallbackMetrics()
    
    // Hysteresis tracking
    private var vtErrorTimestamps: [CFAbsoluteTime] = []
    private var vtSuccessTimestamps: [CFAbsoluteTime] = []
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    
    private let hysteresisDuration: TimeInterval = 2.0  // 2s or 50 frames
    private let errorWindow: TimeInterval = 0.5  // 500ms
    private let errorThreshold: Int = 3  // ≥3 errors
    private let successWindow: TimeInterval = 1.0  // 1s
    private let minCacheHitRate: Double = 0.70  // 70%
    
    // MARK: - Initialization
    
    init(asset: AVAsset, track: AVAssetTrack, clipID: UUID, config: ScrubFeatureFlags.Config) {
        self.asset = asset
        self.track = track
        self.clipID = clipID
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Tracks VT error for fallback decision
    func trackVTError(code: OSStatus) {
        let now = CFAbsoluteTimeGetCurrent()
        vtErrorTimestamps.append(now)
        
        // Keep only recent errors (within window)
        vtErrorTimestamps = vtErrorTimestamps.filter { now - $0 < errorWindow }
        
        // Check if we should activate fallback
        if vtErrorTimestamps.count >= errorThreshold && !isActive {
            let rate = Double(vtErrorTimestamps.count) / errorWindow
            print("[IG_FALLBACK] enter reason=vt_fail rate=\(String(format: "%.1f", rate))/s window=\(errorWindow)s clip=\(clipID)")
            
            state = .active(since: now, reason: "vt_fail_rate")
            metrics.activations += 1
            metrics.lastActivationTime = now
            
            // Create generator
            createGenerator()
        }
    }
    
    /// Tracks VT success for exit decision
    func trackVTSuccess() {
        let now = CFAbsoluteTimeGetCurrent()
        vtSuccessTimestamps.append(now)
        
        // Keep only recent successes
        vtSuccessTimestamps = vtSuccessTimestamps.filter { now - $0 < successWindow }
        
        // Check if we can deactivate
        if isActive {
            checkDeactivation()
        }
    }
    
    /// Tracks cache hit/miss for exit decision
    func trackCacheHit(_ hit: Bool) {
        if hit {
            cacheHits += 1
        } else {
            cacheMisses += 1
        }
    }
    
    /// Decodes frame using ImageGenerator
    func decodeFrame(at targetPTS: TimeInterval, isScrubbing: Bool) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        guard isActive else {
            throw NSError(domain: "ImageGeneratorFallback", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Fallback not active"])
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Ensure generator exists
        if generator == nil {
            createGenerator()
        }
        
        guard let generator = generator else {
            throw NSError(domain: "ImageGeneratorFallback", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create generator"])
        }
        
        // Configure tolerances based on scrubbing state
        if isScrubbing {
            // Small tolerance during live scrubbing for performance
            let frameDuration = 1.0 / 24.0  // Assume 24fps, adjust as needed
            generator.requestedTimeToleranceBefore = CMTime(seconds: frameDuration / 2, preferredTimescale: 24000)
            generator.requestedTimeToleranceAfter = CMTime(seconds: frameDuration / 2, preferredTimescale: 24000)
        } else {
            // Exact frame when stopped
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        
        // Request frame
        let requestedTime = CMTime(seconds: targetPTS, preferredTimescale: 24000)
        var actualTime: CMTime = .zero
        
        let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)
        
        // Convert CGImage to CVPixelBuffer
        let pixelBuffer = try convertToPixelBuffer(cgImage: cgImage)
        
        let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000
        
        // Update metrics
        metrics.framesDecoded += 1
        let alpha = 0.1
        metrics.avgDecodeTimeMS = metrics.avgDecodeTimeMS * (1 - alpha) + duration * alpha
        
        let actualPTS = actualTime.seconds
        
        print("[IG_DECODE] req=\(String(format: "%.3f", targetPTS)) actual=\(String(format: "%.3f", actualPTS)) dur=\(String(format: "%.1f", duration))ms scrub=\(isScrubbing)")
        
        return (pixelBuffer, actualPTS)
    }
    
    /// Returns current state
    var isActive: Bool {
        if case .active = state {
            return true
        }
        return false
    }
    
    /// Forces deactivation
    func forceDeactivate(reason: String) {
        if isActive {
            print("[IG_FALLBACK] exit reason=\(reason) forced=true")
            state = .inactive
            generator = nil
            metrics.deactivations += 1
            metrics.lastDeactivationTime = CFAbsoluteTimeGetCurrent()
        }
    }
    
    /// Returns current metrics
    func getMetrics() -> FallbackMetrics {
        return metrics
    }
    
    // MARK: - Private Methods
    
    private func createGenerator() {
        let newGenerator = AVAssetImageGenerator(asset: asset)
        newGenerator.appliesPreferredTrackTransform = true
        newGenerator.requestedTimeToleranceBefore = .zero
        newGenerator.requestedTimeToleranceAfter = .zero
        
        // Match VT color space settings
        if #available(macOS 12.0, *) {
            newGenerator.apertureMode = .cleanAperture
        }
        
        generator = newGenerator
        print("[IG_GENERATOR] Created for clip=\(clipID)")
    }
    
    private func checkDeactivation() {
        guard case .active(let since, _) = state else { return }
        
        let now = CFAbsoluteTimeGetCurrent()
        let activeDuration = now - since
        
        // Must be active for at least hysteresis duration
        guard activeDuration >= hysteresisDuration else { return }
        
        // Check VT error rate (must be 0 in last second)
        let recentErrors = vtErrorTimestamps.filter { now - $0 < successWindow }
        guard recentErrors.isEmpty else { return }
        
        // Check cache hit rate
        let totalAccesses = cacheHits + cacheMisses
        let hitRate = totalAccesses > 0 ? Double(cacheHits) / Double(totalAccesses) : 0
        
        guard hitRate >= minCacheHitRate else {
            print("[IG_FALLBACK] stay reason=low_cache_hit_rate rate=\(String(format: "%.1f", hitRate * 100))%")
            return
        }
        
        // All conditions met - deactivate
        print("[IG_FALLBACK] exit reason=stable errors=0 hitRate=\(String(format: "%.1f", hitRate * 100))% duration=\(String(format: "%.1f", activeDuration))s")
        
        state = .inactive
        generator = nil
        metrics.deactivations += 1
        metrics.lastDeactivationTime = now
        
        // Reset tracking
        vtErrorTimestamps.removeAll()
        vtSuccessTimestamps.removeAll()
        cacheHits = 0
        cacheMisses = 0
    }
    
    private func convertToPixelBuffer(cgImage: CGImage) throws -> CVPixelBuffer {
        let width = cgImage.width
        let height = cgImage.height
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "ImageGeneratorFallback", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw NSError(domain: "ImageGeneratorFallback", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
    }
}
