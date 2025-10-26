import AVFoundation
import CoreVideo

/// SIMPLE scrub decoder - reuses reader when possible for speed
/// Creates fresh AVAssetReader only when needed
actor SimpleScrubDecoder {
    
    let asset: AVAsset
    let track: AVAssetTrack
    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config
    
    // Cache the last reader and its time range
    private var cachedReader: AVAssetReader?
    private var cachedOutput: AVAssetReaderTrackOutput?
    private var cachedWindowStart: TimeInterval = 0
    private var cachedWindowEnd: TimeInterval = 0
    
    init(asset: AVAsset, track: AVAssetTrack, clipID: UUID, config: ScrubFeatureFlags.Config) {
        self.asset = asset
        self.track = track
        self.clipID = clipID
        self.config = config
    }
    
    /// Decodes frame at target time - FAST with reader reuse
    func decodeFrame(at targetTime: TimeInterval) async throws -> (pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        // Validate input
        guard targetTime >= 0 && targetTime < 10000 else {
            throw NSError(domain: "SimpleScrubDecoder", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid time: \(targetTime)"])
        }
        
        print("🎯 [SimpleScrubDecoder] Requested frame at t=\(String(format: "%.3f", targetTime))s")
        
        // OPTIMIZATION: Reuse reader if target is in cached window
        // CRITICAL: For reverse scrubbing, use TINY window centered on target!
        // Problem: Large windows cause AVAssetReader to find wrong keyframes
        let windowSize: TimeInterval = 0.1  // TINY 100ms window for accuracy!
        let windowStart = max(0.0, targetTime - 0.05)  // Start 50ms before target
        let windowEnd = windowStart + windowSize
        
        print("   📖 Window: \(String(format: "%.3f", windowStart))s - \(String(format: "%.3f", windowEnd))s")
        
        let needsNewReader = cachedReader == nil || 
                            targetTime < cachedWindowStart || 
                            targetTime > cachedWindowEnd ||
                            cachedReader?.status == .failed ||
                            cachedReader?.status == .cancelled
        
        if needsNewReader {
            // Clean up old reader
            cachedReader?.cancelReading()
            cachedReader = nil
            cachedOutput = nil
            
            // Create new reader
            let reader = try AVAssetReader(asset: asset)
            
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: windowStart, preferredTimescale: 24000),
                duration: CMTime(seconds: windowSize, preferredTimescale: 24000)
            )
            
            // Configure output
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            
            guard reader.canAdd(output) else {
                throw NSError(domain: "SimpleScrubDecoder", code: -2,
                             userInfo: [NSLocalizedDescriptionKey: "Cannot add output"])
            }
            
            reader.add(output)
            
            guard reader.startReading() else {
                let error = reader.error?.localizedDescription ?? "unknown"
                throw NSError(domain: "SimpleScrubDecoder", code: -3,
                             userInfo: [NSLocalizedDescriptionKey: "Failed to start reading: \(error)"])
            }
            
            cachedReader = reader
            cachedOutput = output
            cachedWindowStart = windowStart
            cachedWindowEnd = windowEnd
        }
        
        guard let output = cachedOutput else {
            throw NSError(domain: "SimpleScrubDecoder", code: -5,
                         userInfo: [NSLocalizedDescriptionKey: "No output available"])
        }
        
        // Find closest frame to target
        var closestFrame: (CVPixelBuffer, TimeInterval)?
        var closestDistance = Double.infinity
        
        // Read frames until we find the closest one
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let distance = abs(pts - targetTime)
            
            if distance < closestDistance, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                closestDistance = distance
                closestFrame = (pixelBuffer, pts)
                
                // If we're within 1ms, that's good enough
                if distance < 0.001 {
                    break
                }
            }
            
            // Stop if we've passed the target significantly
            if pts > targetTime + 0.1 {
                break
            }
        }
        
        guard let (pixelBuffer, pts) = closestFrame else {
            // If no frame found, invalidate cache and retry once
            cachedReader?.cancelReading()
            cachedReader = nil
            cachedOutput = nil
            
            print("   ❌ No frame found near \(String(format: "%.3f", targetTime))s")
            throw NSError(domain: "SimpleScrubDecoder", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "No frame found near \(targetTime)"])
        }
        
        let error = abs(pts - targetTime) * 1000
        print("   ✅ Found frame at t=\(String(format: "%.3f", pts))s (error: \(String(format: "%.1f", error))ms)")
        
        return (pixelBuffer, pts)
    }
    
    func invalidate() async {
        // Clean up cached reader
        cachedReader?.cancelReading()
        cachedReader = nil
        cachedOutput = nil
    }
}
