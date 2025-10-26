import Foundation
import AVFoundation
import CoreVideo
import Metal
import os.signpost

/// Central frame server with unified cache architecture (AE-style)
/// Manages RAM cache, disk cache, and on-demand rendering/decoding
actor FrameServer {

    // MARK: - Types

    struct ViewSpec: Hashable, Codable {
        let layerStack: [UUID]
        let masks: [UUID]?
        let blends: [BlendMode]?
        let roi: CGRect?
        let displayTransform: DisplayTransform
        let quality: Quality
        let colorSpace: ColorSpace
        let effects: [String]?  // Effect hashes

        enum BlendMode: String, Codable {
            case normal, multiply, screen, overlay, softLight
        }

        enum DisplayTransform: String, Codable {
            case sdr, hdr10, hlg, dolbyVision
        }

        enum Quality: String, Codable {
            case draft, half, full
        }

        enum ColorSpace: String, Codable {
            case rec709, rec2020, p3, srgb
        }

        var hash: String {
            // Compute stable hash for caching
            var hasher = Hasher()
            hasher.combine(layerStack)
            hasher.combine(masks)
            hasher.combine(blends)
            hasher.combine(roi)
            hasher.combine(displayTransform)
            hasher.combine(quality)
            hasher.combine(colorSpace)
            hasher.combine(effects)
            return "\(hasher.finalize())"
        }
    }

    struct CacheKey: Hashable {
        let compID: UUID
        let time: TimeInterval  // Quantized to frame boundary
        let tileRect: CGRect?
        let viewSpecHash: String
        let scale: Float
        let quality: ViewSpec.Quality
        let colorSpace: ViewSpec.ColorSpace
        let effectsHash: String?

        var diskKey: String {
            var components = [
                compID.uuidString,
                String(format: "%.4f", time),
                viewSpecHash
            ]

            if let tile = tileRect {
                components.append("tile_\(tile.origin.x)_\(tile.origin.y)_\(tile.size.width)_\(tile.size.height)")
            }

            components.append("s\(scale)")
            components.append(quality.rawValue)
            components.append(colorSpace.rawValue)

            if let fx = effectsHash {
                components.append("fx_\(fx)")
            }

            return components.joined(separator: "_")
        }
    }

    struct CacheEntry {
        let key: CacheKey
        let pixelBuffer: CVPixelBuffer
        let cost: Int  // Memory cost in bytes
        let decodeCost: TimeInterval  // Time to decode/render
        let timestamp: CFAbsoluteTime
        let accessCount: Int
        let isPinned: Bool
    }

    private struct DiskCacheHeader {
        struct Plane {
            let bytesPerRow: UInt32
            let height: UInt32
            let dataLength: UInt32
        }

        static let magic: UInt32 = 0x434E4D58  // 'CNMX'
        static let version: UInt32 = 1

        let width: UInt32
        let height: UInt32
        let pixelFormat: UInt32
        let planeCount: UInt32
        let planes: [Plane]

        func serialized() -> Data {
            var data = Data()
            data.reserveCapacity(32 + planes.count * 12)
            data.appendUInt32(Self.magic)
            data.appendUInt32(Self.version)
            data.appendUInt32(width)
            data.appendUInt32(height)
            data.appendUInt32(pixelFormat)
            data.appendUInt32(planeCount)
            data.appendUInt32(UInt32(planes.count))
            for plane in planes {
                data.appendUInt32(plane.bytesPerRow)
                data.appendUInt32(plane.height)
                data.appendUInt32(plane.dataLength)
            }
            return data
        }

        static func parse(from data: Data) throws -> (header: DiskCacheHeader, offset: Int) {
            var cursor = 0
            let magic = try data.readUInt32(at: &cursor)
            guard magic == Self.magic else {
                throw DiskCacheError.invalidMagic
            }
            let version = try data.readUInt32(at: &cursor)
            guard version == Self.version else {
                throw DiskCacheError.unsupportedVersion
            }
            let width = try data.readUInt32(at: &cursor)
            let height = try data.readUInt32(at: &cursor)
            let pixelFormat = try data.readUInt32(at: &cursor)
            let planeCount = try data.readUInt32(at: &cursor)
            let payloadPlanes = try data.readUInt32(at: &cursor)

            var planes: [Plane] = []
            planes.reserveCapacity(Int(payloadPlanes))
            for _ in 0..<payloadPlanes {
                let bytesPerRow = try data.readUInt32(at: &cursor)
                let planeHeight = try data.readUInt32(at: &cursor)
                let dataLength = try data.readUInt32(at: &cursor)
                planes.append(Plane(bytesPerRow: bytesPerRow,
                                    height: planeHeight,
                                    dataLength: dataLength))
            }

            let header = DiskCacheHeader(width: width,
                                         height: height,
                                         pixelFormat: pixelFormat,
                                         planeCount: planeCount,
                                         planes: planes)
            return (header, cursor)
        }
    }

    fileprivate enum DiskCacheError: Error {
        case invalidMagic
        case unsupportedVersion
        case malformed
        case incompatible
    }

    private struct TileIndex: Hashable {
        let x: Int
        let y: Int
    }

    enum CacheLevel {
        case ram
        case disk
        case none
    }

    struct FrameRequest {
        let time: TimeInterval
        let compID: UUID
        let viewSpec: ViewSpec
        let deadline: DispatchTime?
        let priority: QualityOfServiceManager.WorkType
        let prefetch: Bool
    }

    // MARK: - Properties

    // Caches
    private var ramCache: [CacheKey: CacheEntry] = [:]
    private var diskCacheURL: URL
    private let maxRAMCacheSize: Int = 4 * 1024 * 1024 * 1024  // 4GB default
    private let maxDiskCacheSize: Int = 8 * 1024 * 1024 * 1024  // 8GB default
    private var currentRAMUsage: Int = 0
    private var currentDiskUsage: Int = 0

    // Pools and resources
    private let pixelBufferPool = ZeroCopyPixelBufferPool.shared
    private let qosManager = QualityOfServiceManager.shared
    private let iframeIndex = IFrameIndexManager.shared

    // Telemetry
    private let frameServerLog = OSLog(subsystem: "com.cinnamon", category: "FrameServer")
    private var cacheHits: [CacheLevel: Int] = [.ram: 0, .disk: 0, .none: 0]
    private var cacheMisses: Int = 0

    // Prefetch management
    private var prefetchTasks: [UUID: Set<Task<Void, Never>>] = [:]
    private var pinnedRanges: [UUID: ClosedRange<TimeInterval>] = [:]

    // Render/Decode delegates
    private var renderDelegate: ((FrameRequest) async throws -> CVPixelBuffer)?
    private var decodeDelegate: ((UUID, TimeInterval) async throws -> CVPixelBuffer)?

    // ROI / Tile state
    private let tileSize: CGFloat = 256
    private var dirtyTiles: [UUID: Set<TileIndex>] = [:]

    // MARK: - Initialization

    init() {
        // Setup disk cache directory
        let cacheBase = FileManager.default.urls(for: .cachesDirectory,
                                                in: .userDomainMask).first!
        self.diskCacheURL = cacheBase.appendingPathComponent("FrameServerCache")

        try? FileManager.default.createDirectory(at: diskCacheURL,
                                               withIntermediateDirectories: true)

        currentDiskUsage = calculateDiskUsage()

        // Start cache maintenance
        Task {
            await startCacheMaintenance()
        }
    }

    // MARK: - Public Methods

    /// Get exact frame with cache-first strategy (AE-style)
    func getExactFrame(at time: TimeInterval,
                      compID: UUID,
                      viewSpec: ViewSpec,
                      deadline: DispatchTime? = nil) async throws -> CVPixelBuffer {

        os_signpost(.begin, log: frameServerLog, name: "GetFrame",
                   "comp:%{public}s time:%.3f", compID.uuidString, time)
        defer {
            os_signpost(.end, log: frameServerLog, name: "GetFrame")
        }

        // Quantize time to frame boundary
        let quantizedTime = quantizeToFrame(time)

        let alignedROI = viewSpec.roi.flatMap { roi -> CGRect? in
            let aligned = alignToTileGrid(roi)
            return aligned.isNull ? nil : aligned
        }
        let effectiveViewSpec = viewSpec.withROI(alignedROI)

        let key = CacheKey(
            compID: compID,
            time: quantizedTime,
            tileRect: effectiveViewSpec.roi,
            viewSpecHash: effectiveViewSpec.hash,
            scale: 1.0,
            quality: effectiveViewSpec.quality,
            colorSpace: effectiveViewSpec.colorSpace,
            effectsHash: nil
        )

        // 1. Check RAM cache
        if let cached = checkRAMCache(key: key) {
            os_signpost(.event, log: frameServerLog, name: "CacheHit", "level:RAM")
            cacheHits[.ram]! += 1
            return cached
        }

        // 2. Check disk cache
        if let diskCached = await checkDiskCache(key: key) {
            os_signpost(.event, log: frameServerLog, name: "CacheHit", "level:Disk")
            cacheHits[.disk]! += 1

            // Promote to RAM cache
            let cacheCost = calculateBufferSize(diskCached)
            await addToRAMCache(key: key,
                                pixelBuffer: diskCached,
                                cost: cacheCost,
                                decodeCost: 0)

            return diskCached
        }

        // 3. Cache miss - need to decode/render
        os_signpost(.event, log: frameServerLog, name: "CacheMiss")
        cacheMisses += 1
        cacheHits[.none]! += 1

        let request = FrameRequest(
            time: quantizedTime,
            compID: compID,
            viewSpec: effectiveViewSpec,
            deadline: deadline,
            priority: .scrubbing,
            prefetch: false
        )

        // 4. Decode or render frame
        let decodeStart = CFAbsoluteTimeGetCurrent()

        let pixelBuffer: CVPixelBuffer
        if let renderDelegate = renderDelegate {
            // Complex comp with effects - use render delegate
            pixelBuffer = try await renderDelegate(request)
        } else if let decodeDelegate = decodeDelegate {
            // Simple video decode
            pixelBuffer = try await decodeDelegate(compID, quantizedTime)
        } else {
            // Fallback to integrated scrub pipeline
            pixelBuffer = try await decodeWithPipeline(compID: compID, time: quantizedTime)
        }

        let decodeCost = CFAbsoluteTimeGetCurrent() - decodeStart

        // 5. Cache the result
        await addToRAMCache(key: key,
                          pixelBuffer: pixelBuffer,
                          cost: calculateBufferSize(pixelBuffer),
                          decodeCost: decodeCost)

        // 6. Async disk cache write (non-blocking)
        Task.detached(priority: .utility) {
            await self.writeToDiskCache(key: key, pixelBuffer: pixelBuffer)
        }

        return pixelBuffer
    }

    /// Prefetch frames around playhead
    func prefetchFrames(around time: TimeInterval,
                       compID: UUID,
                       viewSpec: ViewSpec,
                       backwardFrames: Int = 8,
                       forwardFrames: Int = 16) async {

        // Cancel existing prefetch for this comp
        if let existingTasks = prefetchTasks[compID] {
            for task in existingTasks {
                task.cancel()
            }
        }

        var tasks = Set<Task<Void, Never>>()

        // Calculate frame times to prefetch
        let frameDuration = 1.0 / 30.0  // TODO: Get from composition
        let startTime = time - (Double(backwardFrames) * frameDuration)
        let endTime = time + (Double(forwardFrames) * frameDuration)

        // Create prefetch tasks with proper QoS
        for i in -backwardFrames...forwardFrames {
            let frameTime = time + (Double(i) * frameDuration)
            guard frameTime >= 0 else { continue }

            let task = qosManager.scheduleAdaptive(workType: .prefetch) {
                do {
                    _ = try await self.getExactFrame(at: frameTime,
                                                    compID: compID,
                                                    viewSpec: viewSpec)
                } catch {
                    // Prefetch errors are non-fatal
                    print("[FrameServer] Prefetch failed for \(frameTime): \(error)")
                }
            }

            tasks.insert(task)
        }

        prefetchTasks[compID] = tasks

        print("[FrameServer] Prefetching \(backwardFrames + forwardFrames + 1) frames around \(time)")
    }

    /// Pin a range of frames in cache (won't be evicted)
    func pinFrameRange(_ range: ClosedRange<TimeInterval>, compID: UUID) async {
        pinnedRanges[compID] = range

        // Mark existing cached frames as pinned
        for (key, var entry) in ramCache {
            if key.compID == compID && range.contains(key.time) {
                entry = CacheEntry(
                    key: entry.key,
                    pixelBuffer: entry.pixelBuffer,
                    cost: entry.cost,
                    decodeCost: entry.decodeCost,
                    timestamp: entry.timestamp,
                    accessCount: entry.accessCount,
                    isPinned: true
                )
                ramCache[key] = entry
            }
        }
    }

    /// Clear caches
    func clearCache(level: CacheLevel? = nil) async {
        switch level {
        case .ram:
            clearRAMCache()
        case .disk:
            await clearDiskCache()
        case nil:
            clearRAMCache()
            await clearDiskCache()
        default:
            break
        }
    }

    /// Get cache statistics
    func getCacheStatistics() -> (ramHitRate: Double, diskHitRate: Double, totalHits: Int, totalMisses: Int) {
        let totalHits = cacheHits.values.reduce(0, +)
        let total = totalHits + cacheMisses

        guard total > 0 else {
            return (0, 0, 0, 0)
        }

        let ramHitRate = Double(cacheHits[.ram] ?? 0) / Double(total)
        let diskHitRate = Double(cacheHits[.disk] ?? 0) / Double(total)

        return (ramHitRate, diskHitRate, totalHits, cacheMisses)
    }

    // MARK: - Cache Management

    private func checkRAMCache(key: CacheKey) -> CVPixelBuffer? {
        guard var entry = ramCache[key] else { return nil }

        if let tileRect = key.tileRect, isTileDirty(compID: key.compID, tileRect: tileRect) {
            return nil
        }

        // Update access count and timestamp
        entry = CacheEntry(
            key: entry.key,
            pixelBuffer: entry.pixelBuffer,
            cost: entry.cost,
            decodeCost: entry.decodeCost,
            timestamp: CFAbsoluteTimeGetCurrent(),
            accessCount: entry.accessCount + 1,
            isPinned: entry.isPinned
        )
        ramCache[key] = entry

        return entry.pixelBuffer
    }

    private func checkDiskCache(key: CacheKey) async -> CVPixelBuffer? {
        let fileURL = diskCacheURL.appendingPathComponent(key.diskKey).appendingPathExtension("cache")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        if let tileRect = key.tileRect, isTileDirty(compID: key.compID, tileRect: tileRect) {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let (header, offset) = try DiskCacheHeader.parse(from: data)
            let payloadPlanes = header.planes.count
            let expectedPlanes = max(Int(header.planeCount), 1)
            guard payloadPlanes == expectedPlanes else {
                throw DiskCacheError.malformed
            }

            guard header.width > 0, header.height > 0,
                  header.width <= UInt32(Int32.max), header.height <= UInt32(Int32.max) else {
                throw DiskCacheError.malformed
            }

            let pixelBuffer = try await pixelBufferPool.getBuffer(width: Int32(header.width),
                                                                  height: Int32(header.height),
                                                                  pixelFormat: OSType(header.pixelFormat))

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            let isPlanar = header.planeCount > 0
            var cursor = offset

            let copySucceeded = data.withUnsafeBytes { buffer -> Bool in
                guard let dataBase = buffer.baseAddress else { return false }

                for planeIndex in 0..<payloadPlanes {
                    let planeInfo = header.planes[planeIndex]
                    let dataLength = Int(planeInfo.dataLength)
                    guard cursor + dataLength <= data.count else {
                        return false
                    }

                    let planeStart = dataBase.advanced(by: cursor)
                    cursor += dataLength

                    let destinationBase: UnsafeMutableRawPointer?
                    let destinationBytesPerRow: Int
                    let destinationHeight: Int

                    if isPlanar {
                        destinationBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex)
                        destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
                        destinationHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
                    } else {
                        destinationBase = CVPixelBufferGetBaseAddress(pixelBuffer)
                        destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                        destinationHeight = CVPixelBufferGetHeight(pixelBuffer)
                    }

                    guard let destinationBase else {
                        return false
                    }

                    let rows = min(destinationHeight, Int(planeInfo.height))
                    let sourceRowBytes = Int(planeInfo.bytesPerRow)

                    for row in 0..<rows {
                        let srcPtr = planeStart.advanced(by: row * sourceRowBytes)
                        let dstPtr = destinationBase.advanced(by: row * destinationBytesPerRow)
                        memcpy(dstPtr, srcPtr, min(destinationBytesPerRow, sourceRowBytes))
                    }
                }

                return true
            }

            guard copySucceeded else {
                throw DiskCacheError.malformed
            }

            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)

            return pixelBuffer
        } catch {
            print("[FrameServer] Disk cache read failed for \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }

    private func addToRAMCache(key: CacheKey,
                              pixelBuffer: CVPixelBuffer,
                              cost: Int,
                              decodeCost: TimeInterval) async {

        // Check if we need to evict
        if currentRAMUsage + cost > maxRAMCacheSize {
            await evictFromRAMCache(neededSpace: cost)
        }

        let isPinned = pinnedRanges[key.compID]?.contains(key.time) ?? false

        let entry = CacheEntry(
            key: key,
            pixelBuffer: pixelBuffer,
            cost: cost,
            decodeCost: decodeCost,
            timestamp: CFAbsoluteTimeGetCurrent(),
            accessCount: 1,
            isPinned: isPinned
        )

        ramCache[key] = entry
        currentRAMUsage += cost
    }

    private func evictFromRAMCache(neededSpace: Int) async {
        // Cost-based eviction with LRU factor
        // Score = (decodeCost + renderCost) × bytes × age

        var candidates: [(CacheKey, Double)] = []

        let now = CFAbsoluteTimeGetCurrent()

        for (key, entry) in ramCache {
            // Skip pinned entries
            if entry.isPinned { continue }

            let age = now - entry.timestamp
            let score = (entry.decodeCost + 0.1) * Double(entry.cost) * (1.0 + age)
            candidates.append((key, score))
        }

        // Sort by score (lower score = evict first)
        candidates.sort { $0.1 < $1.1 }

        var freedSpace = 0
        for (key, _) in candidates {
            if let entry = ramCache.removeValue(forKey: key) {
                freedSpace += entry.cost
                currentRAMUsage -= entry.cost

                if freedSpace >= neededSpace {
                    break
                }
            }
        }
    }

    private func writeToDiskCache(key: CacheKey, pixelBuffer: CVPixelBuffer) async {
        let fileURL = diskCacheURL.appendingPathComponent(key.diskKey).appendingPathExtension("cache")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }

        do {
            let data = try serializePixelBuffer(pixelBuffer)
            guard data.count <= maxDiskCacheSize else {
                return
            }

            guard await ensureDiskCapacity(for: data.count) else {
                return
            }

            try data.write(to: fileURL, options: .atomic)
            currentDiskUsage += data.count
            print("[FrameServer] Disk cache write \(fileURL.lastPathComponent) size=\(data.count / 1024)KB usage=\(currentDiskUsage / 1024 / 1024)MB")
            if let tileRect = key.tileRect {
                clearDirtyTiles(compID: key.compID, tileRect: tileRect)
            }
        } catch {
            print("[FrameServer] Disk cache write failed for \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func clearRAMCache() {
        // Keep pinned entries
        let pinned = ramCache.filter { $0.value.isPinned }
        ramCache = pinned

        currentRAMUsage = pinned.values.reduce(0) { $0 + $1.cost }

        print("[FrameServer] Cleared RAM cache, kept \(pinned.count) pinned entries")
    }

    private func clearDiskCache() async {
        if let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheURL,
                                                                      includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }

        currentDiskUsage = 0

        print("[FrameServer] Cleared disk cache")
    }

    // MARK: - Helper Methods

    private func quantizeToFrame(_ time: TimeInterval, frameRate: Double = 30.0) -> TimeInterval {
        let frameDuration = 1.0 / frameRate
        let frameNumber = round(time / frameDuration)
        return frameNumber * frameDuration
    }

    private func calculateBufferSize(_ pixelBuffer: CVPixelBuffer) -> Int {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Estimate based on format
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

    private func serializePixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let isPlanar = planeCount > 0
        let payloadPlanes = max(planeCount, 1)

        var planeDescriptors: [DiskCacheHeader.Plane] = []
        planeDescriptors.reserveCapacity(payloadPlanes)
        var payloads: [Data] = []
        payloads.reserveCapacity(payloadPlanes)

        for plane in 0..<payloadPlanes {
            let baseAddress: UnsafeMutableRawPointer?
            let bytesPerRow: Int
            let planeHeight: Int

            if isPlanar {
                baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
                bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            } else {
                baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
                bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                planeHeight = CVPixelBufferGetHeight(pixelBuffer)
            }

            guard let baseAddress else {
                throw DiskCacheError.incompatible
            }

            let dataLength = bytesPerRow * planeHeight
            guard dataLength <= Int(UInt32.max) else {
                throw DiskCacheError.incompatible
            }

            let planeData = Data(bytes: baseAddress, count: dataLength)
            payloads.append(planeData)
            planeDescriptors.append(DiskCacheHeader.Plane(bytesPerRow: UInt32(bytesPerRow),
                                                          height: UInt32(planeHeight),
                                                          dataLength: UInt32(dataLength)))
        }

        let header = DiskCacheHeader(width: UInt32(CVPixelBufferGetWidth(pixelBuffer)),
                                     height: UInt32(CVPixelBufferGetHeight(pixelBuffer)),
                                     pixelFormat: UInt32(CVPixelBufferGetPixelFormatType(pixelBuffer)),
                                     planeCount: UInt32(planeCount),
                                     planes: planeDescriptors)

        var blob = header.serialized()
        blob.reserveCapacity(blob.count + payloads.reduce(0) { $0 + $1.count })
        for payload in payloads {
            blob.append(payload)
        }

        return blob
    }

    private func calculateDiskUsage() -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheURL,
                                                                          includingPropertiesForKeys: [.totalFileSizeKey],
                                                                          options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total = 0
        for url in contents {
            if let values = try? url.resourceValues(forKeys: [.totalFileSizeKey]),
               let size = values.totalFileSize {
                total += size
            }
        }
        return total
    }

    private func ensureDiskCapacity(for additionalBytes: Int) async -> Bool {
        guard additionalBytes > 0 else { return true }
        if additionalBytes > maxDiskCacheSize {
            return false
        }
        if currentDiskUsage + additionalBytes <= maxDiskCacheSize {
            return true
        }

        let neededSpace = (currentDiskUsage + additionalBytes) - maxDiskCacheSize
        await evictDiskCache(neededSpace: neededSpace)
        return currentDiskUsage + additionalBytes <= maxDiskCacheSize
    }

    private func evictDiskCache(neededSpace: Int) async {
        guard neededSpace > 0 else { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheURL,
                                                                          includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .totalFileSizeKey],
                                                                          options: [.skipsHiddenFiles]) else {
            return
        }

        var entries: [(url: URL, size: Int, date: Date)] = []
        entries.reserveCapacity(contents.count)

        for url in contents {
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .totalFileSizeKey])
                let size = values.totalFileSize ?? 0
                let date = values.contentModificationDate ?? values.creationDate ?? Date.distantPast
                entries.append((url, size, date))
            } catch {
                continue
            }
        }

        guard !entries.isEmpty else { return }

        entries.sort { $0.date < $1.date }

        var freed = 0
        for entry in entries {
            do {
                try FileManager.default.removeItem(at: entry.url)
                freed += entry.size
                currentDiskUsage = max(currentDiskUsage - entry.size, 0)
                print("[FrameServer] Disk cache evict \(entry.url.lastPathComponent) size=\(entry.size / 1024)KB usage=\(currentDiskUsage / 1024 / 1024)MB")
                if freed >= neededSpace {
                    break
                }
            } catch {
                continue
            }
        }
    }

    // MARK: - ROI / Tiling Helpers

    func markDirtyRegion(compID: UUID, rect: CGRect) async {
        let aligned = alignToTileGrid(rect)
        let indices = tileIndices(for: aligned)
        guard !indices.isEmpty else { return }

        var existing = dirtyTiles[compID] ?? []
        let beforeCount = existing.count
        existing.formUnion(indices)
        dirtyTiles[compID] = existing

        if existing.count != beforeCount {
            purgeTilesFromRAM(compID: compID, indices: indices)
        }
    }

    func clearDirtyRegions(for compID: UUID) {
        dirtyTiles.removeValue(forKey: compID)
    }

    func dirtyTileRects(for compID: UUID) -> [CGRect] {
        guard let tiles = dirtyTiles[compID] else { return [] }
        return tiles.map { tileRect(for: $0) }
    }

    func consumeDirtyRects(for compID: UUID) -> [CGRect] {
        guard let tiles = dirtyTiles.removeValue(forKey: compID) else { return [] }
        return tiles.map { tileRect(for: $0) }
    }

    func applyDirtyUpdate(_ update: DirtyRegionTracker.DirtyUpdate) async {
        await markDirtyRegion(compID: update.compID, rect: update.region)
    }

    func getTiles(at time: TimeInterval,
                  compID: UUID,
                  viewSpec: ViewSpec,
                  roi: CGRect,
                  deadline: DispatchTime? = nil) async throws -> [CGRect: CVPixelBuffer] {
        let aligned = alignToTileGrid(roi)
        let indices = tileIndices(for: aligned)
        guard !indices.isEmpty else { return [:] }

        var results: [CGRect: CVPixelBuffer] = [:]
        results.reserveCapacity(indices.count)

        for index in indices {
            let tileRect = tileRect(for: index)
            let tileSpec = viewSpec.withROI(tileRect)
            let buffer = try await getExactFrame(at: time,
                                                 compID: compID,
                                                 viewSpec: tileSpec,
                                                 deadline: deadline)
            results[tileRect] = buffer
        }

        return results
    }

    private func alignToTileGrid(_ rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return CGRect.null }
        let tile = tileSize

        let minX = floor(rect.minX / tile) * tile
        let minY = floor(rect.minY / tile) * tile
        let maxX = ceil(rect.maxX / tile) * tile
        let maxY = ceil(rect.maxY / tile) * tile

        return CGRect(x: minX,
                      y: minY,
                      width: max(maxX - minX, tile),
                      height: max(maxY - minY, tile))
    }

    private func tileRect(for index: TileIndex) -> CGRect {
        let origin = CGPoint(x: CGFloat(index.x) * tileSize,
                             y: CGFloat(index.y) * tileSize)
        return CGRect(origin: origin, size: CGSize(width: tileSize, height: tileSize))
    }

    private func tileIndices(for rect: CGRect) -> Set<TileIndex> {
        let aligned = alignToTileGrid(rect)
        guard aligned.width > 0, aligned.height > 0 else { return [] }

        let minX = Int(floor(aligned.minX / tileSize))
        let maxX = Int(ceil(aligned.maxX / tileSize)) - 1
        let minY = Int(floor(aligned.minY / tileSize))
        let maxY = Int(ceil(aligned.maxY / tileSize)) - 1

        guard maxX >= minX, maxY >= minY else { return [] }

        var result: Set<TileIndex> = []
        for x in minX...maxX {
            for y in minY...maxY {
                result.insert(TileIndex(x: x, y: y))
            }
        }
        return result
    }

    private func isTileDirty(compID: UUID, tileRect: CGRect) -> Bool {
        guard let dirty = dirtyTiles[compID], !dirty.isEmpty else { return false }
        let indices = tileIndices(for: tileRect)
        return !dirty.isDisjoint(with: indices)
    }

    private func clearDirtyTiles(compID: UUID, tileRect: CGRect) {
        guard var dirty = dirtyTiles[compID], !dirty.isEmpty else { return }
        let indices = tileIndices(for: tileRect)
        guard !indices.isEmpty else { return }
        dirty.subtract(indices)
        if dirty.isEmpty {
            dirtyTiles.removeValue(forKey: compID)
        } else {
            dirtyTiles[compID] = dirty
        }
    }

    private func purgeTilesFromRAM(compID: UUID, indices: Set<TileIndex>) {
        guard !indices.isEmpty else { return }

        var keysToRemove: [CacheKey] = []
        for (key, _) in ramCache where key.compID == compID {
            guard let tileRect = key.tileRect else { continue }
            let keyIndices = tileIndices(for: tileRect)
            if !indices.isDisjoint(with: keyIndices) {
                keysToRemove.append(key)
            }
        }

        for key in keysToRemove {
            if let entry = ramCache.removeValue(forKey: key) {
                currentRAMUsage = max(currentRAMUsage - entry.cost, 0)
            }
        }
    }

    private func decodeWithPipeline(compID: UUID, time: TimeInterval) async throws -> CVPixelBuffer {
        // Fallback to existing decode pipeline
        // This would integrate with your existing IntegratedScrubPipeline

        // For now, create a dummy buffer
        let buffer = try await pixelBufferPool.getBuffer(width: 1920, height: 1080)
        return buffer
    }

    // MARK: - Cache Maintenance

    private func startCacheMaintenance() async {
        // Periodic cache cleanup
        while true {
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds

            // Clean old entries
            let now = CFAbsoluteTimeGetCurrent()
            let maxAge: TimeInterval = 300  // 5 minutes

            var toRemove: [CacheKey] = []
            for (key, entry) in ramCache {
                if !entry.isPinned && (now - entry.timestamp) > maxAge {
                    toRemove.append(key)
                }
            }

            for key in toRemove {
                if let entry = ramCache.removeValue(forKey: key) {
                    currentRAMUsage -= entry.cost
                }
            }

            if !toRemove.isEmpty {
                print("[FrameServer] Maintenance: removed \(toRemove.count) stale entries")
            }

            // Report statistics
            let stats = getCacheStatistics()
            print("[FrameServer] Cache stats - RAM hit: \(String(format: "%.1f%%", stats.ramHitRate * 100)), Disk hit: \(String(format: "%.1f%%", stats.diskHitRate * 100))")
        }
    }
}

// MARK: - Global Instance

extension FrameServer {
    static let shared = FrameServer()
}

extension FrameServer.ViewSpec {
    func withROI(_ roi: CGRect?) -> FrameServer.ViewSpec {
        FrameServer.ViewSpec(layerStack: layerStack,
                             masks: masks,
                             blends: blends,
                             roi: roi,
                             displayTransform: displayTransform,
                             quality: quality,
                             colorSpace: colorSpace,
                             effects: effects)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: inout Int) throws -> UInt32 {
        let end = offset + MemoryLayout<UInt32>.size
        guard end <= count else {
            throw FrameServer.DiskCacheError.malformed
        }
        var value: UInt32 = 0
        Swift.withUnsafeMutableBytes(of: &value) { buffer in
            copyBytes(to: buffer, from: offset..<end)
        }
        offset = end
        return UInt32(littleEndian: value)
    }
}
