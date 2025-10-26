import Foundation
import AVFoundation

/// Persistent I-Frame index manager for efficient GOP navigation
/// Stores IDR/CRA/BLA frame positions for quick random access during scrubbing
actor IFrameIndexManager {

    // MARK: - Types

    struct IFrameEntry: Codable {
        let pts: TimeInterval
        let dts: TimeInterval
        let filePosition: Int64
        let frameType: FrameType
        let isKeyframe: Bool
        let size: Int64

        enum FrameType: String, Codable {
            case idr = "IDR"    // Instantaneous Decoder Refresh (H.264/AVC)
            case cra = "CRA"    // Clean Random Access (HEVC)
            case bla = "BLA"    // Broken Link Access (HEVC)
            case sps = "SPS"    // Sequence Parameter Set
            case pps = "PPS"    // Picture Parameter Set
            case vps = "VPS"    // Video Parameter Set (HEVC)
            case regular = "REG"
        }
    }

    struct AssetIndex: Codable {
        let assetID: String
        let trackID: Int32
        let duration: TimeInterval
        let frameRate: Double
        let codec: String
        let width: Int32
        let height: Int32
        let iFrames: [IFrameEntry]
        let averageGOPSize: Int
        let createdAt: Date
        let version: Int

        static let currentVersion = 1
    }

    struct IndexStatistics {
        let totalFrames: Int
        let iFrameCount: Int
        let averageGOPSize: Double
        let minGOPSize: Int
        let maxGOPSize: Int
        let iFrameRatio: Double
    }

    // MARK: - Properties

    private var indices: [String: AssetIndex] = [:]
    private var indexingTasks: [String: Task<AssetIndex?, Error>] = [:]
    private let cacheDirectory: URL
    private let qosManager = QualityOfServiceManager.shared

    // Statistics
    private var indexHits: Int = 0
    private var indexMisses: Int = 0
    private var indexingTime: TimeInterval = 0

    // MARK: - Initialization

    init() {
        // Setup cache directory
        let cacheBase = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first!
        self.cacheDirectory = cacheBase.appendingPathComponent("IFrameIndices")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true)

        // Load existing indices on init
        Task {
            await loadPersistedIndices()
        }
    }

    // MARK: - Public Methods

    /// Get or build index for an asset
    func getIndex(for asset: AVAsset, track: AVAssetTrack) async throws -> AssetIndex {
        let assetID = identifierForAsset(asset)

        // Check memory cache
        if let cached = indices[assetID] {
            indexHits += 1
            return cached
        }

        // Check disk cache
        if let persisted = await loadIndexFromDisk(assetID: assetID) {
            indices[assetID] = persisted
            indexHits += 1
            return persisted
        }

        indexMisses += 1

        // Check if already indexing
        if let existingTask = indexingTasks[assetID] {
            if let result = try await existingTask.value {
                return result
            }
        }

        // Start new indexing task
        let indexTask = qosManager.executeAsync(workType: .analysis) {
            try await self.buildIndex(for: asset, track: track)
        }

        indexingTasks[assetID] = indexTask

        guard let index = try await indexTask.value else {
            throw NSError(domain: "IFrameIndexManager",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to build index"])
        }

        // Cache in memory and persist
        indices[assetID] = index
        await persistIndexToDisk(index)
        indexingTasks.removeValue(forKey: assetID)

        return index
    }

    /// Find nearest I-Frame before target time
    func nearestIFrameBefore(time: TimeInterval, in index: AssetIndex) -> IFrameEntry? {
        let iFrames = index.iFrames
        guard !iFrames.isEmpty else { return nil }

        // Binary search for nearest I-Frame before time
        var low = 0
        var high = iFrames.count - 1
        var result: IFrameEntry?

        while low <= high {
            let mid = (low + high) / 2
            let frame = iFrames[mid]

            if frame.pts <= time {
                result = frame
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }

    /// Find nearest I-Frame after target time
    func nearestIFrameAfter(time: TimeInterval, in index: AssetIndex) -> IFrameEntry? {
        let iFrames = index.iFrames
        guard !iFrames.isEmpty else { return nil }

        // Binary search for nearest I-Frame after time
        for frame in iFrames {
            if frame.pts > time {
                return frame
            }
        }

        return nil
    }

    /// Get I-Frames in range
    func iFramesInRange(from startTime: TimeInterval,
                       to endTime: TimeInterval,
                       in index: AssetIndex) -> [IFrameEntry] {
        return index.iFrames.filter { frame in
            frame.pts >= startTime && frame.pts <= endTime
        }
    }

    /// Calculate statistics for an index
    func statistics(for index: AssetIndex) -> IndexStatistics {
        let iFrames = index.iFrames
        guard !iFrames.isEmpty else {
            return IndexStatistics(totalFrames: 0,
                                 iFrameCount: 0,
                                 averageGOPSize: 0,
                                 minGOPSize: 0,
                                 maxGOPSize: 0,
                                 iFrameRatio: 0)
        }

        var gopSizes: [Int] = []
        for i in 0..<(iFrames.count - 1) {
            let currentPTS = iFrames[i].pts
            let nextPTS = iFrames[i + 1].pts
            let gopDuration = nextPTS - currentPTS
            let gopSize = Int(gopDuration * index.frameRate)
            gopSizes.append(gopSize)
        }

        let totalFrames = Int(index.duration * index.frameRate)
        let avgGOP = gopSizes.isEmpty ? 0 : Double(gopSizes.reduce(0, +)) / Double(gopSizes.count)
        let minGOP = gopSizes.min() ?? 0
        let maxGOP = gopSizes.max() ?? 0
        let ratio = Double(iFrames.count) / Double(totalFrames)

        return IndexStatistics(totalFrames: totalFrames,
                             iFrameCount: iFrames.count,
                             averageGOPSize: avgGOP,
                             minGOPSize: minGOP,
                             maxGOPSize: maxGOP,
                             iFrameRatio: ratio)
    }

    /// Clear all indices
    func clearAll() async {
        indices.removeAll()

        // Cancel ongoing indexing
        for task in indexingTasks.values {
            task.cancel()
        }
        indexingTasks.removeAll()

        // Clear disk cache
        if let contents = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                      includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }

        print("[IFrameIndex] Cleared all indices")
    }

    // MARK: - Private Methods

    private func buildIndex(for asset: AVAsset, track: AVAssetTrack) async throws -> AssetIndex? {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let reader = try? AVAssetReader(asset: asset) else {
            print("[IFrameIndex] Failed to create reader for asset")
            return nil
        }

        // Configure output for sample data inspection
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            print("[IFrameIndex] Failed to start reading: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }

        var iFrames: [IFrameEntry] = []
        var frameCount = 0
        let assetID = identifierForAsset(asset)

        // Get track info
        let frameRate = Double(track.nominalFrameRate)
        let duration = CMTimeGetSeconds(track.timeRange.duration)
        let formatDesc = (track.formatDescriptions as? [CMFormatDescription])?.first
        let codec = formatDesc != nil ? detectCodec(from: formatDesc!) : "unknown"
        let dimensions = track.naturalSize

        // Process samples
        while reader.status == .reading {
            autoreleasepool {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { return }

                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                let dts = CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sampleBuffer))

                // Check if this is a keyframe
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                         createIfNecessary: false) as? [[CFString: Any]]
                let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                let isDependedOn = !(attachments?.first?[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? true)

                if isKeyframe || isDependedOn {
                    let frameType = detectFrameType(from: sampleBuffer, codec: codec)
                    let dataSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)

                    let entry = IFrameEntry(
                        pts: pts,
                        dts: dts.isNaN ? pts : dts,
                        filePosition: Int64(frameCount),
                        frameType: frameType,
                        isKeyframe: isKeyframe,
                        size: Int64(dataSize)
                    )

                    iFrames.append(entry)
                }

                frameCount += 1

                // Progress reporting for long videos
                if frameCount % 1000 == 0 {
                    let progress = pts / duration
                    print("[IFrameIndex] Indexing \(assetID): \(Int(progress * 100))%")
                }
            }
        }

        reader.cancelReading()

        // Calculate average GOP size
        let avgGOPSize = iFrames.count > 0 ? frameCount / iFrames.count : 0

        let index = AssetIndex(
            assetID: assetID,
            trackID: track.trackID,
            duration: duration,
            frameRate: frameRate,
            codec: codec,
            width: Int32(dimensions.width),
            height: Int32(dimensions.height),
            iFrames: iFrames,
            averageGOPSize: avgGOPSize,
            createdAt: Date(),
            version: AssetIndex.currentVersion
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        indexingTime += elapsed

        print("[IFrameIndex] Built index for \(assetID):")
        print("  - Duration: \(duration)s")
        print("  - Total frames: \(frameCount)")
        print("  - I-Frames: \(iFrames.count)")
        print("  - Avg GOP: \(avgGOPSize)")
        print("  - Indexing time: \(String(format: "%.2f", elapsed))s")

        return index
    }

    private func detectCodec(from formatDesc: CMFormatDescription) -> String {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc)
        switch mediaSubType {
        case kCMVideoCodecType_H264:
            return "H.264/AVC"
        case kCMVideoCodecType_HEVC:
            return "H.265/HEVC"
        case kCMVideoCodecType_AppleProRes422:
            return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444:
            return "ProRes 4444"
        default:
            return FourCharCode(mediaSubType).toString()
        }
    }

    private func detectFrameType(from sampleBuffer: CMSampleBuffer, codec: String) -> IFrameEntry.FrameType {
        // Simple heuristic - would need deeper NAL unit parsing for accuracy
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                 createIfNecessary: false) as? [[CFString: Any]]
        let isSync = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isSync {
            if codec.contains("HEVC") {
                return .cra  // Simplified - would need NAL parsing
            } else {
                return .idr  // Simplified - would need NAL parsing
            }
        }

        return .regular
    }

    private func identifierForAsset(_ asset: AVAsset) -> String {
        if let urlAsset = asset as? AVURLAsset {
            return urlAsset.url.lastPathComponent
        }
        return "\(asset.hash)"
    }

    private func persistIndexToDisk(_ index: AssetIndex) async {
        let url = cacheDirectory.appendingPathComponent("\(index.assetID).iframeindex")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(index)
            try data.write(to: url)
            print("[IFrameIndex] Persisted index for \(index.assetID)")
        } catch {
            print("[IFrameIndex] Failed to persist index: \(error)")
        }
    }

    private func loadIndexFromDisk(assetID: String) async -> AssetIndex? {
        let url = cacheDirectory.appendingPathComponent("\(assetID).iframeindex")

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let index = try decoder.decode(AssetIndex.self, from: data)

            // Check version compatibility
            if index.version == AssetIndex.currentVersion {
                print("[IFrameIndex] Loaded index from disk for \(assetID)")
                return index
            } else {
                print("[IFrameIndex] Index version mismatch, rebuilding")
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            print("[IFrameIndex] Failed to load index: \(error)")
        }

        return nil
    }

    private func loadPersistedIndices() async {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                         includingPropertiesForKeys: nil) else {
            return
        }

        for file in contents where file.pathExtension == "iframeindex" {
            let assetID = file.deletingPathExtension().lastPathComponent
            if let index = await loadIndexFromDisk(assetID: assetID) {
                indices[assetID] = index
            }
        }

        print("[IFrameIndex] Loaded \(indices.count) persisted indices")
    }
}

// MARK: - Utilities

extension FourCharCode {
    func toString() -> String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// MARK: - Global Instance

extension IFrameIndexManager {
    static let shared = IFrameIndexManager()
}