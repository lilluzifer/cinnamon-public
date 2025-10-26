import Foundation
import CoreVideo
import AVFoundation
import os.signpost

/// Mini-GOP ring buffer for efficient reverse scrubbing
/// Maintains a small window of decoded frames around the playhead
actor MiniGOPRingBuffer {

    // MARK: - Types

    struct FrameEntry {
        let pixelBuffer: CVPixelBuffer
        let pts: TimeInterval
        let clipID: UUID
        let isKeyframe: Bool
        let decodeCost: TimeInterval
        let timestamp: CFAbsoluteTime
    }

    struct BufferConfig {
        let minSize: Int       // Minimum frames to keep
        let maxSize: Int       // Maximum frames in buffer
        let backwardBias: Double  // Ratio of backward frames (0.0-1.0)
        let codec: Codec

        enum Codec {
            case hevc
            case avc
            case prores
            case other

            var recommendedSize: Int {
                switch self {
                case .hevc:
                    return 12  // HEVC needs more frames due to complex prediction
                case .avc:
                    return 8   // H.264 typical GOP size
                case .prores:
                    return 4   // ProRes is intra-frame, needs less
                case .other:
                    return 6
                }
            }

            var optimalBackwardBias: Double {
                switch self {
                case .hevc, .avc:
                    return 0.75  // 75% backward for inter-frame codecs
                case .prores:
                    return 0.5   // 50/50 for intra-frame
                case .other:
                    return 0.6
                }
            }
        }

        static func optimal(for codec: Codec, direction: ScrubDirection) -> BufferConfig {
            let size = codec.recommendedSize
            let bias = direction == .reverse ? codec.optimalBackwardBias : (1.0 - codec.optimalBackwardBias)

            return BufferConfig(
                minSize: size,
                maxSize: size * 2,
                backwardBias: bias,
                codec: codec
            )
        }
    }

    enum ScrubDirection {
        case forward
        case reverse
        case bidirectional
    }

    struct Statistics {
        let totalFrames: Int
        let hitRate: Double
        let averageDecodeCost: TimeInterval
        let memoryUsage: Int
        let oldestFrame: TimeInterval?
        let newestFrame: TimeInterval?
        let keyframeCount: Int
    }

    // MARK: - Properties

    private var ringBuffer: [FrameEntry] = []
    private var bufferConfig: BufferConfig
    private var playheadPosition: TimeInterval = 0
    private var currentDirection: ScrubDirection = .bidirectional

    // Statistics
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    private var totalDecodeCost: TimeInterval = 0
    private var decodeCount: Int = 0

    // Telemetry
    private let bufferLog = OSLog(subsystem: "com.cinnamon", category: "MiniGOP")

    // Decode delegate
    private var decodeCallback: ((UUID, TimeInterval) async throws -> (CVPixelBuffer, TimeInterval))?

    // MARK: - Initialization

    init(config: BufferConfig) {
        self.bufferConfig = config
        ringBuffer.reserveCapacity(config.maxSize)
    }

    // MARK: - Public Methods

    /// Update buffer configuration based on codec and direction
    func updateConfiguration(codec: BufferConfig.Codec, direction: ScrubDirection) {
        bufferConfig = BufferConfig.optimal(for: codec, direction: direction)
        currentDirection = direction

        // Trim buffer if needed
        if ringBuffer.count > bufferConfig.maxSize {
            trimBuffer()
        }

        print("[MiniGOP] Updated config - size: \(bufferConfig.minSize)-\(bufferConfig.maxSize), bias: \(bufferConfig.backwardBias)")
    }

    /// Get frame from buffer or decode if needed
    func getFrame(at time: TimeInterval, clipID: UUID) async throws -> CVPixelBuffer? {
        os_signpost(.begin, log: bufferLog, name: "GetFrame", "time:%.3f", time)
        defer {
            os_signpost(.end, log: bufferLog, name: "GetFrame")
        }

        // Update playhead position
        playheadPosition = time

        // Check if frame exists in buffer
        if let existing = findFrame(at: time, clipID: clipID, tolerance: 0.001) {
            cacheHits += 1
            os_signpost(.event, log: bufferLog, name: "CacheHit")
            return existing.pixelBuffer
        }

        // Cache miss - need to decode
        cacheMisses += 1
        os_signpost(.event, log: bufferLog, name: "CacheMiss")

        // Decode the frame
        guard let decode = decodeCallback else {
            throw NSError(domain: "MiniGOPRingBuffer",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "No decode callback set"])
        }

        let decodeStart = CFAbsoluteTimeGetCurrent()
        let (pixelBuffer, actualPTS) = try await decode(clipID, time)
        let decodeCost = CFAbsoluteTimeGetCurrent() - decodeStart

        // Add to buffer
        await addFrame(pixelBuffer: pixelBuffer,
                      pts: actualPTS,
                      clipID: clipID,
                      isKeyframe: false,  // TODO: Detect from frame
                      decodeCost: decodeCost)

        // Maintain buffer around new position
        await maintainBuffer(around: time, clipID: clipID)

        return pixelBuffer
    }

    /// Prefill buffer around a position
    func prefillBuffer(around time: TimeInterval,
                      clipID: UUID,
                      frameDuration: TimeInterval) async {
        os_signpost(.begin, log: bufferLog, name: "Prefill", "time:%.3f", time)
        defer {
            os_signpost(.end, log: bufferLog, name: "Prefill")
        }

        playheadPosition = time

        // Calculate frame range based on direction and bias
        let backwardFrames = Int(Double(bufferConfig.minSize) * bufferConfig.backwardBias)
        let forwardFrames = bufferConfig.minSize - backwardFrames

        let startTime = time - (Double(backwardFrames) * frameDuration)
        let endTime = time + (Double(forwardFrames) * frameDuration)

        print("[MiniGOP] Prefilling \(bufferConfig.minSize) frames: [\(String(format: "%.3f", startTime)) - \(String(format: "%.3f", endTime))]")

        // Decode frames in priority order based on direction
        var frameTimes: [TimeInterval] = []

        switch currentDirection {
        case .reverse:
            // Prioritize backward frames
            for i in (0...backwardFrames).reversed() {
                frameTimes.append(time - Double(i) * frameDuration)
            }
            for i in 1...forwardFrames {
                frameTimes.append(time + Double(i) * frameDuration)
            }

        case .forward:
            // Prioritize forward frames
            for i in 0...forwardFrames {
                frameTimes.append(time + Double(i) * frameDuration)
            }
            for i in (1...backwardFrames).reversed() {
                frameTimes.append(time - Double(i) * frameDuration)
            }

        case .bidirectional:
            // Interleave for balanced loading
            for i in 0...max(backwardFrames, forwardFrames) {
                if i <= backwardFrames {
                    frameTimes.append(time - Double(i) * frameDuration)
                }
                if i <= forwardFrames && i > 0 {
                    frameTimes.append(time + Double(i) * frameDuration)
                }
            }
        }

        // Decode frames
        for frameTime in frameTimes {
            guard frameTime >= 0 else { continue }

            // Skip if already in buffer
            if findFrame(at: frameTime, clipID: clipID, tolerance: frameDuration * 0.5) != nil {
                continue
            }

            do {
                _ = try await getFrame(at: frameTime, clipID: clipID)
            } catch {
                print("[MiniGOP] Failed to prefill frame at \(frameTime): \(error)")
            }
        }
    }

    /// Clear buffer
    func clear() {
        ringBuffer.removeAll()
        cacheHits = 0
        cacheMisses = 0
        totalDecodeCost = 0
        decodeCount = 0
        print("[MiniGOP] Buffer cleared")
    }

    /// Clear frames for specific clip
    func clearClip(_ clipID: UUID) {
        ringBuffer.removeAll { $0.clipID == clipID }
        print("[MiniGOP] Cleared frames for clip \(clipID.uuidString.prefix(8))")
    }

    /// Set decode callback
    func setDecodeCallback(_ callback: @escaping (UUID, TimeInterval) async throws -> (CVPixelBuffer, TimeInterval)) {
        self.decodeCallback = callback
    }

    /// Get buffer statistics
    func getStatistics() -> Statistics {
        let totalRequests = cacheHits + cacheMisses
        let hitRate = totalRequests > 0 ? Double(cacheHits) / Double(totalRequests) : 0

        let avgDecodeCost = decodeCount > 0 ? totalDecodeCost / Double(decodeCount) : 0

        let memoryUsage = ringBuffer.reduce(0) { total, entry in
            total + estimateBufferSize(entry.pixelBuffer)
        }

        let keyframes = ringBuffer.filter { $0.isKeyframe }.count

        let times = ringBuffer.map { $0.pts }.sorted()
        let oldest = times.first
        let newest = times.last

        return Statistics(
            totalFrames: ringBuffer.count,
            hitRate: hitRate,
            averageDecodeCost: avgDecodeCost,
            memoryUsage: memoryUsage,
            oldestFrame: oldest,
            newestFrame: newest,
            keyframeCount: keyframes
        )
    }

    // MARK: - Private Methods

    private func findFrame(at time: TimeInterval,
                          clipID: UUID,
                          tolerance: TimeInterval) -> FrameEntry? {
        return ringBuffer.first { entry in
            entry.clipID == clipID && abs(entry.pts - time) <= tolerance
        }
    }

    private func addFrame(pixelBuffer: CVPixelBuffer,
                         pts: TimeInterval,
                         clipID: UUID,
                         isKeyframe: Bool,
                         decodeCost: TimeInterval) async {
        // Check if frame already exists
        if findFrame(at: pts, clipID: clipID, tolerance: 0.0001) != nil {
            return
        }

        let entry = FrameEntry(
            pixelBuffer: pixelBuffer,
            pts: pts,
            clipID: clipID,
            isKeyframe: isKeyframe,
            decodeCost: decodeCost,
            timestamp: CFAbsoluteTimeGetCurrent()
        )

        ringBuffer.append(entry)

        // Update statistics
        totalDecodeCost += decodeCost
        decodeCount += 1

        // Trim if over max size
        if ringBuffer.count > bufferConfig.maxSize {
            trimBuffer()
        }
    }

    private func trimBuffer() {
        guard !ringBuffer.isEmpty else { return }

        // Sort by distance from playhead
        let sorted = ringBuffer.sorted { lhs, rhs in
            let lhsDistance = abs(lhs.pts - playheadPosition)
            let rhsDistance = abs(rhs.pts - playheadPosition)

            // Prefer keeping frames in the direction we're moving
            switch currentDirection {
            case .reverse:
                // Keep backward frames
                if lhs.pts <= playheadPosition && rhs.pts > playheadPosition {
                    return true
                } else if lhs.pts > playheadPosition && rhs.pts <= playheadPosition {
                    return false
                }
            case .forward:
                // Keep forward frames
                if lhs.pts >= playheadPosition && rhs.pts < playheadPosition {
                    return true
                } else if lhs.pts < playheadPosition && rhs.pts >= playheadPosition {
                    return false
                }
            case .bidirectional:
                break
            }

            // Otherwise sort by distance
            return lhsDistance < rhsDistance
        }

        // Keep the closest frames up to max size
        ringBuffer = Array(sorted.prefix(bufferConfig.maxSize))
    }

    private func maintainBuffer(around time: TimeInterval, clipID: UUID) async {
        // Remove frames too far from playhead
        let maxDistance = Double(bufferConfig.maxSize / 2) * (1.0 / 30.0)  // Assume 30fps

        ringBuffer.removeAll { entry in
            abs(entry.pts - time) > maxDistance
        }

        // TODO: Trigger prefill if buffer is getting low
        if ringBuffer.count < bufferConfig.minSize {
            await prefillBuffer(around: time, clipID: clipID, frameDuration: 1.0 / 30.0)
        }
    }

    private func estimateBufferSize(_ pixelBuffer: CVPixelBuffer) -> Int {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            var totalSize = 0
            for plane in 0..<planeCount {
                let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let planeBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                totalSize += planeHeight * planeBytesPerRow
            }
            return totalSize
        } else {
            return height * bytesPerRow
        }
    }
}

// MARK: - Integration Extensions

extension MiniGOPRingBuffer {
    /// Create buffer optimized for a specific asset
    static func createOptimized(for asset: AVAsset, track: AVAssetTrack) -> MiniGOPRingBuffer {
        // Detect codec from track
        let codec: BufferConfig.Codec = {
            guard let formatDescs = track.formatDescriptions as? [CMFormatDescription],
                  let formatDesc = formatDescs.first else {
                return .other
            }

            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
            switch mediaSubType {
            case kCMVideoCodecType_HEVC:
                return .hevc
            case kCMVideoCodecType_H264:
                return .avc
            case kCMVideoCodecType_AppleProRes422,
                 kCMVideoCodecType_AppleProRes4444,
                 kCMVideoCodecType_AppleProRes422HQ,
                 kCMVideoCodecType_AppleProRes422LT,
                 kCMVideoCodecType_AppleProRes422Proxy:
                return .prores
            default:
                return .other
            }
        }()

        let config = BufferConfig.optimal(for: codec, direction: .bidirectional)
        return MiniGOPRingBuffer(config: config)
    }
}