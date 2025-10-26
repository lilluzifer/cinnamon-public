import AVFoundation

actor SpotProxyManager {
    struct ZoneKey: Hashable, Sendable {
        let clipID: UUID
        let bucket: Int64
    }

    struct ProxyInfo: Sendable {
        let zoneID: UUID
        let clipID: UUID
        let url: URL
        let range: ClosedRange<Int64>
        let reason: String
        let context: String
    }

    enum Decision: Sendable {
        case original
        case proxy(info: ProxyInfo)
    }

    final class ProxyZone {
        enum State {
            case pending
            case ready
            case failed
        }

        let key: ZoneKey
        let zoneID: UUID
        let clipID: UUID
        var range: ClosedRange<Int64>
        var reason: String
        var context: String
        var state: State
        var createdAt: CFAbsoluteTime
        var lastAccess: CFAbsoluteTime
        var url: URL?
        var exportStartMs: Int64
        var exportDurationMs: Int64
        var anchorMs: Int64

        init(key: ZoneKey,
             zoneID: UUID,
             clipID: UUID,
             range: ClosedRange<Int64>,
             reason: String,
             context: String,
             state: State,
             createdAt: CFAbsoluteTime,
             lastAccess: CFAbsoluteTime,
             exportStartMs: Int64,
             exportDurationMs: Int64,
             anchorMs: Int64) {
            self.key = key
            self.zoneID = zoneID
            self.clipID = clipID
            self.range = range
            self.reason = reason
            self.context = context
            self.state = state
            self.createdAt = createdAt
            self.lastAccess = lastAccess
            self.exportStartMs = exportStartMs
            self.exportDurationMs = exportDurationMs
            self.anchorMs = anchorMs
        }
    }

    static let shared = SpotProxyManager()

    private var zones: [UUID: [ZoneKey: ProxyZone]] = [:]
    private var zoneLRU: [ZoneKey] = []
    private var activeZoneID: [UUID: UUID] = [:]
    private var lateFrameHistory: [UUID: [Int64]] = [:]
    private var pendingLateFrameTrigger: [UUID: Int64] = [:]
    private var exportTasks: [UUID: Task<Void, Never>] = [:]

    private let maxZones = 32
    private let zoneTTL: CFTimeInterval = 20 * 60
    private let bucketSpanMs: Int64 = 2000
    private let lateFrameWindowMs: Int64 = 300
    private let lateFrameThreshold = 3
    private let exportMarginMs: Int64 = 300

    private init() {}

    func ensureSpotProxy(clipID: UUID,
                         asset: AVAsset,
                         aroundAbsMs: Int64,
                         spanMs: Int64 = 4000,
                         reason: String,
                         context: String,
                         raAnchorMs: Int64? = nil) async {
        await pruneExpiredZones()
        let normalizedSpan = max(spanMs, 1000)
        let bucket = max(Int64(0), aroundAbsMs) / bucketSpanMs
        let key = ZoneKey(clipID: clipID, bucket: bucket)
        let calculation = computeExportRange(aroundAbsMs: aroundAbsMs,
                                             spanMs: normalizedSpan,
                                             raAnchorMs: raAnchorMs)
        let now = CFAbsoluteTimeGetCurrent()

        if let existing = zones[clipID]?[key] {
            let mergedRange = merge(existing.range, with: calculation.range)
            let newStart = min(existing.exportStartMs, calculation.exportStartMs)
            let newDuration = max(existing.exportDurationMs, calculation.exportDurationMs)
            let needsReexport = mergedRange != existing.range || newStart != existing.exportStartMs || newDuration != existing.exportDurationMs

            existing.reason = reason
            existing.context = context
            existing.anchorMs = aroundAbsMs
            existing.range = mergedRange
            existing.exportStartMs = newStart
            existing.exportDurationMs = newDuration
            touch(existing)

            if needsReexport {
                exportTasks[existing.zoneID]?.cancel()
                exportTasks.removeValue(forKey: existing.zoneID)
                removeZoneFiles(existing)
                existing.url = nil
                existing.state = .pending
            } else if existing.state == .failed {
                existing.state = .pending
            }

            if existing.state == .pending, exportTasks[existing.zoneID] == nil {
                startExport(for: existing,
                            asset: asset,
                            exportStartMs: existing.exportStartMs,
                            exportDurationMs: existing.exportDurationMs)
            }
            return
        }

        let zone = ProxyZone(key: key,
                             zoneID: UUID(),
                             clipID: clipID,
                             range: calculation.range,
                             reason: reason,
                             context: context,
                             state: .pending,
                             createdAt: now,
                             lastAccess: now,
                             exportStartMs: calculation.exportStartMs,
                             exportDurationMs: calculation.exportDurationMs,
                             anchorMs: aroundAbsMs)

        print("[SPOT_PROXY_TRIGGER] clip=\(clipID.uuidString.prefix(8)) t=\(aroundAbsMs)ms reason=\(reason) context=\(context)")
        insert(zone: zone)
        startExport(for: zone,
                    asset: asset,
                    exportStartMs: calculation.exportStartMs,
                    exportDurationMs: calculation.exportDurationMs)
    }

    func decision(for clipID: UUID, absMs: Int64) async -> Decision {
        await pruneExpiredZones()
        guard let zonesForClip = zones[clipID] else {
            if activeZoneID.removeValue(forKey: clipID) != nil {
                print("[SPOT_PROXY_LEAVE] clip=\(clipID.uuidString.prefix(8)) reason=out-of-range")
            }
            return .original
        }

        for zone in zonesForClip.values where zone.state == .ready {
            if let url = zone.url, zone.range.contains(absMs) {
                touch(zone)
                if activeZoneID[clipID] != zone.zoneID {
                    activeZoneID[clipID] = zone.zoneID
                    print("[SPOT_PROXY_HIT] clip=\(clipID.uuidString.prefix(8)) t=\(absMs)ms source=proxy context=\(zone.context)")
                }
                let info = ProxyInfo(zoneID: zone.zoneID,
                                     clipID: clipID,
                                     url: url,
                                     range: zone.range,
                                     reason: zone.reason,
                                     context: zone.context)
                return .proxy(info: info)
            }
        }

        if activeZoneID.removeValue(forKey: clipID) != nil {
            print("[SPOT_PROXY_LEAVE] clip=\(clipID.uuidString.prefix(8)) reason=out-of-range")
        }
        return .original
    }

    func noteDeadlineFailure(clipID: UUID,
                              targetAbsMs: Int64,
                              asset: AVAsset) async {
        await ensureSpotProxy(clipID: clipID,
                              asset: asset,
                              aroundAbsMs: targetAbsMs,
                              spanMs: 4000,
                              reason: "deadline-decode",
                              context: "deadline")
    }

    func clearActiveHit(for clipID: UUID, reason: String = "reset") {
        if activeZoneID.removeValue(forKey: clipID) != nil {
            print("[SPOT_PROXY_LEAVE] clip=\(clipID.uuidString.prefix(8)) reason=\(reason)")
        }
    }

    func markPlaybackFailure(clipID: UUID, zoneID: UUID, reason: String) async {
        guard let clipZones = zones[clipID] else { return }
        for (key, zone) in clipZones where zone.zoneID == zoneID {
            zone.state = .failed
            removeZoneFiles(zone)
            zone.url = nil
            zones[clipID]?[key] = zone
            if activeZoneID[clipID] == zoneID {
                activeZoneID.removeValue(forKey: clipID)
                print("[SPOT_PROXY_LEAVE] clip=\(clipID.uuidString.prefix(8)) reason=\(reason)")
            }
            print("[SPOT_PROXY_FAIL] clip=\(clipID.uuidString.prefix(8)) zone=\(zoneID) error=playback-prepare context=\(zone.context)")
            break
        }
    }

    func recordLateFrame(clipID: UUID, absMs: Int64) async {
        var history = lateFrameHistory[clipID] ?? []
        history.append(absMs)
        let windowStart = absMs - lateFrameWindowMs
        history = history.filter { $0 >= windowStart }
        lateFrameHistory[clipID] = history
        if history.count >= lateFrameThreshold {
            pendingLateFrameTrigger[clipID] = absMs
            lateFrameHistory[clipID] = []
            print("[SPOT_PROXY_TRIGGER] clip=\(clipID.uuidString.prefix(8)) t=\(absMs)ms reason=late-frames context=pending")
        }
    }

    func consumeLateFrameTrigger(for clipID: UUID) -> Int64? {
        return pendingLateFrameTrigger.removeValue(forKey: clipID)
    }

    func invalidateClip(_ clipID: UUID, reason: String) async {
        guard let zonesForClip = zones.removeValue(forKey: clipID) else {
            activeZoneID.removeValue(forKey: clipID)
            pendingLateFrameTrigger.removeValue(forKey: clipID)
            lateFrameHistory.removeValue(forKey: clipID)
            return
        }
        for zone in zonesForClip.values {
            remove(zone: zone, reason: reason)
        }
        activeZoneID.removeValue(forKey: clipID)
        pendingLateFrameTrigger.removeValue(forKey: clipID)
        lateFrameHistory.removeValue(forKey: clipID)
    }

    func debugLogStatus(clipID: UUID, label: String) async {
        let clipPrefix = clipID.uuidString.prefix(8)
        guard let zonesForClip = zones[clipID], !zonesForClip.isEmpty else {
            print("[SPOT_PROXY_STATUS] clip=\(clipPrefix) label=\(label) zones=0 active=none")
            return
        }

        let activeZone = activeZoneID[clipID]
        let sortedZones = zonesForClip.values.sorted { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
                return lhs.zoneID.uuidString < rhs.zoneID.uuidString
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        for zone in sortedZones {
            let state: String
            switch zone.state {
            case .pending: state = "pending"
            case .ready: state = "ready"
            case .failed: state = "failed"
            }

            let urlLabel = zone.url?.lastPathComponent ?? "nil"
            let activeMark = zone.zoneID == activeZone ? "*" : "-"
            let lastAccessDelta = Int((CFAbsoluteTimeGetCurrent() - zone.lastAccess) * 1000.0)
            print("[SPOT_PROXY_STATUS] clip=\(clipPrefix) label=\(label) zone=\(zone.zoneID.uuidString.prefix(8)) state=\(state) range=[\(zone.range.lowerBound),\(zone.range.upperBound)]ms export=[\(zone.exportStartMs),\(zone.exportStartMs + zone.exportDurationMs)]ms anchor=\(zone.anchorMs)ms url=\(urlLabel) ctx=\(zone.context) reason=\(zone.reason) lastAccessMs=\(lastAccessDelta) active=\(activeMark)")
        }
    }

    struct EnsureResult: Sendable {
        enum Status: String, Sendable {
            case ready
            case pending
            case failed
            case missing
        }

        let status: Status
        let didRequestExport: Bool
        let zoneID: UUID?
    }

    func ensureCoverageIfNeeded(clipID: UUID,
                                asset: AVAsset,
                                aroundAbsMs: Int64,
                                spanMs: Int64 = 4000,
                                reason: String,
                                context: String) async -> EnsureResult {
        await pruneExpiredZones()

        if let existing = zoneCovering(clipID: clipID, absMs: aroundAbsMs), existing.state == .ready {
            return EnsureResult(status: .ready, didRequestExport: false, zoneID: existing.zoneID)
        }

        await ensureSpotProxy(clipID: clipID,
                              asset: asset,
                              aroundAbsMs: aroundAbsMs,
                              spanMs: spanMs,
                              reason: reason,
                              context: context)

        if let updated = zoneCovering(clipID: clipID, absMs: aroundAbsMs) {
            switch updated.state {
            case .ready:
                return EnsureResult(status: .ready, didRequestExport: true, zoneID: updated.zoneID)
            case .pending:
                return EnsureResult(status: .pending, didRequestExport: true, zoneID: updated.zoneID)
            case .failed:
                return EnsureResult(status: .failed, didRequestExport: true, zoneID: updated.zoneID)
            }
        }

        return EnsureResult(status: .missing, didRequestExport: true, zoneID: nil)
    }

    // MARK: - Private helpers

    private func zoneCovering(clipID: UUID, absMs: Int64) -> ProxyZone? {
        guard let clipZones = zones[clipID] else { return nil }
        for zone in clipZones.values where zone.range.contains(absMs) {
            return zone
        }
        return nil
    }

    private func computeExportRange(aroundAbsMs: Int64,
                                    spanMs: Int64,
                                    raAnchorMs: Int64?) -> (range: ClosedRange<Int64>, exportStartMs: Int64, exportDurationMs: Int64) {
        let halfSpan = spanMs / 2
        var start = max(aroundAbsMs - halfSpan, 0)
        if let raAnchorMs {
            start = min(start, max(raAnchorMs, 0))
        }
        let end = start + spanMs
        let exportStartMs = max(start - exportMarginMs, 0)
        let exportEndMs = end + exportMarginMs
        let exportDurationMs = max(spanMs, exportEndMs - exportStartMs)
        return (start...end, exportStartMs, exportDurationMs)
    }

    private func merge(_ lhs: ClosedRange<Int64>, with rhs: ClosedRange<Int64>) -> ClosedRange<Int64> {
        let lower = min(lhs.lowerBound, rhs.lowerBound)
        let upper = max(lhs.upperBound, rhs.upperBound)
        return lower...upper
    }

    private func insert(zone: ProxyZone) {
        var clipZones = zones[zone.clipID] ?? [:]
        clipZones[zone.key] = zone
        zones[zone.clipID] = clipZones
        touch(zone)
        enforceCapacity()
    }

    private func touch(_ zone: ProxyZone) {
        zone.lastAccess = CFAbsoluteTimeGetCurrent()
        zoneLRU.removeAll { $0 == zone.key }
        zoneLRU.append(zone.key)
    }

    private func enforceCapacity() {
        var total = zones.values.reduce(0) { $0 + $1.count }
        while total > maxZones, let oldestKey = zoneLRU.first {
            zoneLRU.removeFirst()
            guard let zone = zones[oldestKey.clipID]?[oldestKey] else { continue }
            remove(zone: zone, reason: "lru")
            total -= 1
        }
    }

    private func pruneExpiredZones() async {
        let now = CFAbsoluteTimeGetCurrent()
        var expiredKeys: [ZoneKey] = []
        for (clipID, clipZones) in zones {
            for (key, zone) in clipZones {
                if now - zone.lastAccess > zoneTTL {
                    expiredKeys.append(key)
                }
            }
        }

        guard !expiredKeys.isEmpty else { return }

        for key in expiredKeys {
            guard let zone = zones[key.clipID]?[key] else { continue }
            remove(zone: zone, reason: "expired")
        }
        zoneLRU.removeAll { expiredKeys.contains($0) }
    }

    private func remove(zone: ProxyZone, reason: String) {
        zones[zone.clipID]?[zone.key] = nil
        if zones[zone.clipID]?.isEmpty == true {
            zones.removeValue(forKey: zone.clipID)
        }
        zoneLRU.removeAll { $0 == zone.key }
        exportTasks[zone.zoneID]?.cancel()
        exportTasks.removeValue(forKey: zone.zoneID)
        removeZoneFiles(zone)
        if activeZoneID[zone.clipID] == zone.zoneID {
            activeZoneID.removeValue(forKey: zone.clipID)
            print("[SPOT_PROXY_LEAVE] clip=\(zone.clipID.uuidString.prefix(8)) reason=\(reason)")
        }
    }

    private func startExport(for zone: ProxyZone,
                             asset: AVAsset,
                             exportStartMs: Int64,
                             exportDurationMs: Int64) {
        if exportTasks[zone.zoneID] != nil { return }
        print("[SPOT_PROXY_START] clip=\(zone.clipID.uuidString.prefix(8)) bucket=\(zone.key.bucket) range=[\(zone.range.lowerBound), \(zone.range.upperBound)]ms codec=ProRes422Proxy context=\(zone.context)")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.exportProxy(for: zone,
                                                     asset: asset,
                                                     exportStartMs: exportStartMs,
                                                     exportDurationMs: exportDurationMs)
                await self.markZoneReady(zone, url: url)
            } catch {
                await self.markZoneFailed(zone, error: error)
            }
            await self.cleanupTask(for: zone.zoneID)
        }
        exportTasks[zone.zoneID] = task
    }

    private func cleanupTask(for zoneID: UUID) async {
        exportTasks.removeValue(forKey: zoneID)
    }

    private func markZoneReady(_ zone: ProxyZone, url: URL) async {
        zone.url = url
        zone.state = .ready
        touch(zone)
        print("[SPOT_PROXY_READY] clip=\(zone.clipID.uuidString.prefix(8)) range=[\(zone.range.lowerBound), \(zone.range.upperBound)]ms url=\(url.lastPathComponent) context=\(zone.context)")
    }

    private func markZoneFailed(_ zone: ProxyZone, error: Error) async {
        zone.state = .failed
        print("[SPOT_PROXY_FAIL] clip=\(zone.clipID.uuidString.prefix(8)) zone=\(zone.zoneID) error=\(error.localizedDescription)")
    }

    private func exportProxy(for zone: ProxyZone,
                              asset: AVAsset,
                              exportStartMs: Int64,
                              exportDurationMs: Int64) async throws -> URL {
        let durationCM = try await asset.load(.duration)
        let assetDurationSeconds = max(CMTimeGetSeconds(durationCM), 0)
        let startSeconds = max(Double(exportStartMs) / 1000.0, 0)
        let maxDuration = max(assetDurationSeconds - startSeconds, 0.5)
        let requestedDuration = max(Double(exportDurationMs) / 1000.0, 0.5)
        let durationSeconds = min(requestedDuration, maxDuration)
        let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let durationTime = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, duration: durationTime)

        let preset = selectPreset(for: asset)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: preset) else {
            throw NSError(domain: "SpotProxy", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }

        let proxiesDir = try proxiesDirectory()
        let outputURL = proxiesDir.appendingPathComponent("proxy_\(zone.clipID.uuidString)_\(zone.zoneID).mov")
        try? FileManager.default.removeItem(at: outputURL)

        export.outputURL = outputURL
        export.outputFileType = preferredFileType(for: export)
        export.timeRange = timeRange
        export.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: export.error ?? NSError(domain: "SpotProxy", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown export failure"]))
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "SpotProxy", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"]))
                default:
                    return
                }
            }
        }

        return outputURL
    }

    private func proxiesDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SpotProxies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private func selectPreset(for asset: AVAsset) -> String {
        let desired = "Apple ProRes 422 Proxy"
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        if presets.contains(desired) {
            return desired
        }
        if presets.contains(AVAssetExportPresetHighestQuality) {
            return AVAssetExportPresetHighestQuality
        }
        if presets.contains(AVAssetExportPresetPassthrough) {
            return AVAssetExportPresetPassthrough
        }
        return presets.first ?? AVAssetExportPresetMediumQuality
    }

    private func preferredFileType(for export: AVAssetExportSession) -> AVFileType {
        if export.supportedFileTypes.contains(.mov) {
            return .mov
        }
        if let preferred = export.supportedFileTypes.first {
            return preferred
        }
        return .mov
    }

    private func removeZoneFiles(_ zone: ProxyZone) {
        if let url = zone.url {
            try? FileManager.default.removeItem(at: url)
            zone.url = nil
        }
    }
}
