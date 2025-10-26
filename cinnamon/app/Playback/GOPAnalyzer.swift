import Foundation
import AVFoundation

struct RAKey: Hashable, CustomStringConvertible {
    let trackObjectID: ObjectIdentifier
    let trackID: Int32
    let streamID: Int32
    let epoch: UInt32
    let idrDTSms: Int64

    var description: String {
        "track=\(trackID) stream=\(streamID) epoch=\(epoch) idrDTSms=\(idrDTSms) asset=\(String(format: "%08X", trackObjectID.hashValue))"
    }

    var seconds: TimeInterval { TimeInterval(idrDTSms) / 1000.0 }
}

private struct TrackStreamKey: Hashable {
    let trackObjectID: ObjectIdentifier
    let trackID: Int32
    let streamID: Int32
}

private struct TimestampKey: Hashable {
    let trackObjectID: ObjectIdentifier
    let trackID: Int32
    let streamID: Int32
    let absMs: Int64
}

private struct GOPCacheKey: Hashable {
    let trackObjectID: ObjectIdentifier
    let trackID: Int32
    let streamID: Int32
    let idrPTS: TimeInterval
}

private struct TrackStreamState {
    var nextEpoch: UInt32 = 1
}

private struct RARecord {
    let key: RAKey
    let absMs: Int64
}

private extension Array {
    func binarySearchInsertionIndex(by areInIncreasingOrder: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if areInIncreasingOrder(self[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private struct TimeLookupKey: Hashable {
    let trackKey: TrackStreamKey
    let absMs: Int64
}

private struct LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        return value
    }

    mutating func setValue(_ value: Value, for key: Key) {
        storage[key] = value
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        if order.count > capacity, let removed = order.first {
            order.removeFirst()
            storage.removeValue(forKey: removed)
        }
    }

    mutating func clear() {
        storage.removeAll()
        order.removeAll()
    }
}

@inline(__always)
func canonicalMs(_ time: CMTime) -> Int64 {
    let scaled = CMTimeConvertScale(time, timescale: 1000, method: .default)
    return Int64(scaled.value)
}

func makeRAKey(track: AVAssetTrack, streamID: Int32, epoch: UInt32, idrDTS: CMTime) -> RAKey {
    RAKey(trackObjectID: ObjectIdentifier(track), trackID: track.trackID, streamID: streamID, epoch: epoch, idrDTSms: canonicalMs(idrDTS))
}

/// Analyzes GOP (Group of Pictures) structure for efficient scrubbing.
/// Distinguishes true random-access points (IDR / CRA / BLA) from dependent frames.
actor GOPAnalyzer {
    
    // MARK: - Types

    struct GOPInfo {
        let idrPTS: TimeInterval
        let nextIDRPTS: TimeInterval?
        let frameCount: Int
        let timestamp: CFAbsoluteTime
        
        var isValid: Bool {
            let maxAge: TimeInterval = 30.0  // Cache for 30 seconds
            return CFAbsoluteTimeGetCurrent() - timestamp < maxAge
        }
    }
    
    struct RandomAccessFlags {
        let attachmentsPresent: Bool
        let notSync: Bool?
        let dependsOnOthers: Bool?
        let randomAccess: Bool?
        let noTemporalReference: Bool?
        let partialSync: Bool?
        let isDependedOnByOthers: Bool?
    }
    
    enum RandomAccessKind: String {
        case idr
        case cra
        case bla
        case partial
        case none
    }
    
    struct RandomAccessResult {
        let pts: TimeInterval
        let key: RAKey
        let kind: RandomAccessKind
        let flags: RandomAccessFlags
        let isFallback: Bool
        let requiresPreroll: Bool
    }

    enum Codec {
        case avc
        case hevc
    }
    
    // MARK: - Properties
    
    private var gopCache: [GOPCacheKey: GOPInfo] = [:]
    private struct RAFailEntry {
        var count: Int
        var expiresAt: CFAbsoluteTime

        mutating func bump(now: CFAbsoluteTime, ttl: CFAbsoluteTime) {
            count &+= 1
            expiresAt = now + ttl
        }
    }

    private var raResultsByKey: [RAKey: RandomAccessResult] = [:]
    private var failCount: [RAKey: RAFailEntry] = [:]
    private var failureLRU: [RAKey] = []
    private let failureCapacity = 256
    private let failureTTL: CFAbsoluteTime = 5.0
    private var quarantineUntil: [RAKey: CFAbsoluteTime] = [:]
    private let fallbackWindowSize: TimeInterval = 1.0  // 1 second fallback window
    private var trackStates: [TrackStreamKey: TrackStreamState] = [:]
    private var recordsByTrack: [TrackStreamKey: [RARecord]] = [:]
    private var keyByTimestamp: [TimestampKey: RAKey] = [:]
    private var absTimeByKey: [RAKey: Int64] = [:]
    private var prevCache = LRUCache<TimeLookupKey, RAKey>(capacity: 64)
    private var nearestCache = LRUCache<TimeLookupKey, RAKey>(capacity: 64)
    private var indexEpoch: UInt64 = 0
    
    func resetAllCaches() {
        gopCache.removeAll()
        raResultsByKey.removeAll()
        failCount.removeAll()
        failureLRU.removeAll()
        quarantineUntil.removeAll()
        trackStates.removeAll()
        recordsByTrack.removeAll()
        keyByTimestamp.removeAll()
        absTimeByKey.removeAll()
        prevCache.clear()
        nearestCache.clear()
        indexEpoch &+= 1
    }

    func currentEpoch() -> UInt64 {
        indexEpoch
    }

    // MARK: - Helpers

    private func decodeTimestamp(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        if decodeTime.isValid && !decodeTime.isIndefinite {
            return decodeTime
        }
        return CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    private func trackStreamKey(for track: AVAssetTrack, streamID: Int32) -> TrackStreamKey {
        TrackStreamKey(trackObjectID: ObjectIdentifier(track), trackID: track.trackID, streamID: streamID)
    }

    private func trackStreamKey(for key: RAKey) -> TrackStreamKey {
        TrackStreamKey(trackObjectID: key.trackObjectID, trackID: key.trackID, streamID: key.streamID)
    }

    private func timestampKey(track: AVAssetTrack, streamID: Int32, absMs: Int64) -> TimestampKey {
        TimestampKey(trackObjectID: ObjectIdentifier(track), trackID: track.trackID, streamID: streamID, absMs: absMs)
    }

    private func timestampKey(for key: RAKey) -> TimestampKey {
        TimestampKey(trackObjectID: key.trackObjectID, trackID: key.trackID, streamID: key.streamID, absMs: absTimeByKey[key] ?? key.idrDTSms)
    }

    private func gopCacheKey(for track: AVAssetTrack, streamID: Int32, idrPTS: TimeInterval) -> GOPCacheKey {
        GOPCacheKey(trackObjectID: ObjectIdentifier(track), trackID: track.trackID, streamID: streamID, idrPTS: idrPTS)
    }

    private func gopCacheKey(for key: RAKey, idrPTS: TimeInterval) -> GOPCacheKey {
        GOPCacheKey(trackObjectID: key.trackObjectID, trackID: key.trackID, streamID: key.streamID, idrPTS: idrPTS)
    }

    private func insertRecord(_ record: RARecord, into trackKey: TrackStreamKey) {
        var list = recordsByTrack[trackKey] ?? []
        let insertIndex = list.binarySearchInsertionIndex { $0.absMs < record.absMs }
        if insertIndex < list.count && list[insertIndex].absMs == record.absMs {
            list[insertIndex] = record
        } else if insertIndex < list.count && list[insertIndex].key == record.key {
            list[insertIndex] = record
        } else {
            list.insert(record, at: insertIndex)
        }
        recordsByTrack[trackKey] = list
        prevCache.clear()
        nearestCache.clear()
    }

    private func existingRandomAccess(track: AVAssetTrack,
                                      streamID: Int32,
                                      absMs: Int64) -> RandomAccessResult? {
        let tsKey = timestampKey(track: track, streamID: streamID, absMs: absMs)
        if let key = keyByTimestamp[tsKey], let result = raResultsByKey[key] {
            return result
        }
        return nil
    }

    private func storeRandomAccess(_ result: RandomAccessResult) {
        raResultsByKey[result.key] = result
        let trackKey = trackStreamKey(for: result.key)
        let fallbackMs = absTimeByKey[result.key] ?? result.key.idrDTSms
        let absMs = quantizedMilliseconds(for: result.pts, fallback: fallbackMs)
        absTimeByKey[result.key] = absMs
        let tsKey = TimestampKey(trackObjectID: result.key.trackObjectID,
                                 trackID: result.key.trackID,
                                 streamID: result.key.streamID,
                                 absMs: absMs)
        keyByTimestamp[tsKey] = result.key
        insertRecord(RARecord(key: result.key, absMs: absMs), into: trackKey)
        // Telemetry: removed noisy GOP_INDEX logging
    }

    private func quantizedMilliseconds(for seconds: TimeInterval, fallback: Int64) -> Int64 {
        guard seconds.isFinite else { return fallback }
        let scaled = seconds * 1000.0
        guard scaled.isFinite else { return fallback }
        let rounded = scaled.rounded()
        if rounded < Double(Int64.min) || rounded > Double(Int64.max) {
            return fallback
        }
        return Int64(rounded)
    }

    private func resolveKey(for track: AVAssetTrack, idrDTS: CMTime) -> RAKey {
        let streamID: Int32 = 0
        let absMs = canonicalMs(idrDTS)
        let tsKey = timestampKey(track: track, streamID: streamID, absMs: absMs)
        if let existing = keyByTimestamp[tsKey] {
            return existing
        }
        let trackKey = trackStreamKey(for: track, streamID: streamID)
        var state = trackStates[trackKey] ?? TrackStreamState()
        let epoch = state.nextEpoch
        state.nextEpoch &+= 1
        trackStates[trackKey] = state
        let key = makeRAKey(track: track, streamID: streamID, epoch: epoch, idrDTS: idrDTS)
        absTimeByKey[key] = absMs
        keyByTimestamp[tsKey] = key
        insertRecord(RARecord(key: key, absMs: absMs), into: trackKey)
        return key
    }

    private func indexedPrevious(for key: RAKey, minDeltaMs: Int64) -> RandomAccessResult? {
        let trackKey = trackStreamKey(for: key)
        guard let records = recordsByTrack[trackKey], let currentAbs = absTimeByKey[key] else {
            return nil
        }
        var index = records.firstIndex { $0.key == key }
        if index == nil {
            index = records.binarySearchInsertionIndex { $0.absMs < currentAbs }
        }
        guard let currentIndex = index, currentIndex > 0 else { return nil }
        for candidateIndex in stride(from: currentIndex - 1, through: 0, by: -1) {
            let record = records[candidateIndex]
            let delta = record.absMs - currentAbs
            if delta <= -minDeltaMs, let ra = raResultsByKey[record.key] {
                return ra
            }
        }
        return nil
    }

    private func prevSyncBefore(trackKey: TrackStreamKey, absMs: Int64) -> RAKey? {
        let lookup = TimeLookupKey(trackKey: trackKey, absMs: absMs)
        if let cached = prevCache.value(for: lookup) {
            return cached
        }
        guard let records = recordsByTrack[trackKey], !records.isEmpty else { return nil }
        let adjusted = adjustedLookup(absMs)
        let index = records.binarySearchInsertionIndex { $0.absMs < adjusted }
        guard index > 0 else { return nil }
        let record = records[index - 1]
        prevCache.setValue(record.key, for: lookup)
        return record.key
    }

    private func nearestAtOrBefore(trackKey: TrackStreamKey, absMs: Int64) -> RAKey? {
        let lookup = TimeLookupKey(trackKey: trackKey, absMs: absMs)
        if let cached = nearestCache.value(for: lookup) {
            return cached
        }
        guard let records = recordsByTrack[trackKey], !records.isEmpty else { return nil }
        let index = records.binarySearchInsertionIndex { $0.absMs < absMs }
        if index < records.count, records[index].absMs == absMs {
            let key = records[index].key
            nearestCache.setValue(key, for: lookup)
            return key
        }
        if index > 0 {
            let key = records[index - 1].key
            nearestCache.setValue(key, for: lookup)
            return key
        }
        return nil
    }

    func prevSyncBefore(absMs: Int64, track: AVAssetTrack) -> RAKey? {
        let trackKey = trackStreamKey(for: track, streamID: 0)
        return prevSyncBefore(trackKey: trackKey, absMs: absMs)
    }

    func atOrBefore(absMs: Int64, track: AVAssetTrack) -> RAKey? {
        let trackKey = trackStreamKey(for: track, streamID: 0)
        return nearestAtOrBefore(trackKey: trackKey, absMs: absMs)
    }

    func timeMs(for key: RAKey) -> Int64? {
        absTimeByKey[key]
    }

    func prevSyncAbsMs(before absMs: Int64, track: AVAssetTrack) -> Int64? {
        guard let key = prevSyncBefore(absMs: absMs, track: track) else { return nil }
        return absTimeByKey[key]
    }

    func nextSyncAbsMs(after absMs: Int64, track: AVAssetTrack) -> Int64? {
        let trackKey = trackStreamKey(for: track, streamID: 0)
        guard let records = recordsByTrack[trackKey], !records.isEmpty else { return nil }
        let index = records.binarySearchInsertionIndex { $0.absMs <= absMs }
        if index < records.count {
            let key = records[index].key
            return records[index].absMs
        }
        return nil
    }

    func syncRangeMs(for track: AVAssetTrack) -> (min: Int64, max: Int64)? {
        let trackKey = trackStreamKey(for: track, streamID: 0)
        guard let list = recordsByTrack[trackKey], let first = list.first?.absMs, let last = list.last?.absMs else {
            return nil
        }
        return (first, last)
    }

    func isNearCut(absMs: Int64, track: AVAssetTrack, edgeSlackMs: Int64 = 150) -> Bool {
        if let prev = prevSyncAbsMs(before: absMs, track: track), absMs - prev <= edgeSlackMs {
            return true
        }
        if let next = nextSyncAbsMs(after: absMs, track: track), next - absMs <= edgeSlackMs {
            return true
        }
        return false
    }

    private func adjustedLookup(_ absMs: Int64) -> Int64 {
        if absMs <= Int64.min + 1 { return Int64.min }
        return absMs - 1
    }

    func randomAccess(for key: RAKey) -> RandomAccessResult? {
        raResultsByKey[key]
    }
    // MARK: - Public Methods
    
    /// Finds the nearest random-access frame (IDR / CRA / BLA) to the specified time.
    /// Returns both the time stamp and classification metadata.
    func findRandomAccess(near time: TimeInterval,
                          asset: AVAsset,
                          track: AVAssetTrack) async throws -> RandomAccessResult {
        let streamID: Int32 = 0
        if let cached = findCachedIDR(near: time, track: track) {
            let idrDTS = CMTime(seconds: cached, preferredTimescale: 1000)
            let absMs = canonicalMs(idrDTS)
            if let existing = existingRandomAccess(track: track,
                                                   streamID: streamID,
                                                   absMs: absMs) {
                return existing
            }
            let key = resolveKey(for: track, idrDTS: idrDTS)
            let result = RandomAccessResult(
                pts: cached,
                key: key,
                kind: .idr,
                flags: RandomAccessFlags(attachmentsPresent: false,
                                          notSync: nil,
                                          dependsOnOthers: nil,
                                          randomAccess: nil,
                                          noTemporalReference: nil,
                                          partialSync: nil,
                                          isDependedOnByOthers: nil),
                isFallback: false,
                requiresPreroll: false
            )
            storeRandomAccess(result)
            return result
        }

        do {
            let result = try await searchForRandomAccess(near: time, asset: asset, track: track)
            storeRandomAccess(result)
            return result
        } catch {
            print("[GOPAnalyzer] IDR detection failed, using fallback: \(error)")
            let idrDTS = CMTime(seconds: time, preferredTimescale: 1000)
            let key = resolveKey(for: track, idrDTS: idrDTS)
            let result = RandomAccessResult(
                pts: time,
                key: key,
                kind: .none,
                flags: RandomAccessFlags(attachmentsPresent: false,
                                          notSync: nil,
                                          dependsOnOthers: nil,
                                          randomAccess: nil,
                                          noTemporalReference: nil,
                                          partialSync: nil,
                                          isDependedOnByOthers: nil),
                isFallback: true,
                requiresPreroll: false
            )
            storeRandomAccess(result)
            return result
        }
    }

    func noteFail(_ key: RAKey) {
        let now = CFAbsoluteTimeGetCurrent()
        var entry = failCount[key] ?? RAFailEntry(count: 0, expiresAt: now + failureTTL)
        entry.bump(now: now, ttl: failureTTL)
        failCount[key] = entry
        touchFailureLRU(key)
    }

    func resetFail(for key: RAKey) {
        failCount[key] = nil
        failureLRU.removeAll { $0 == key }
        quarantineUntil[key] = nil
    }

    func quarantine(_ key: RAKey, until deadline: CFAbsoluteTime) {
        quarantineUntil[key] = deadline
    }

    func prevRandomAccessStrict(from key: RAKey,
                                asset: AVAsset,
                                track: AVAssetTrack,
                                minDeltaMs: Int64 = 16) async throws -> RandomAccessResult? {
        guard let currentAbs = absTimeByKey[key] else { return nil }
        let trackKey = trackStreamKey(for: key)
        if let previousKey = prevSyncBefore(trackKey: trackKey, absMs: currentAbs),
           let previousAbs = absTimeByKey[previousKey],
           currentAbs - previousAbs >= minDeltaMs,
           let prevResult = raResultsByKey[previousKey] {
            return prevResult
        }

        let margin: TimeInterval = max(Double(currentAbs) / 1000.0 - 0.001, 0)
        guard let fallback = try await previousRandomAccess(before: margin,
                                                            asset: asset,
                                                            track: track) else {
            print("[GOP_MISS] key=\(key) reason=noPrevEpoch")
            return nil
        }
        storeRandomAccess(fallback)
        if let prevKey = prevSyncBefore(trackKey: trackKey, absMs: currentAbs),
           let previousAbs = absTimeByKey[prevKey],
           currentAbs - previousAbs >= minDeltaMs,
           let prevResult = raResultsByKey[prevKey] {
            return prevResult
        }
        return nil
    }

    func nextAfterFail(current: RandomAccessResult,
                       asset: AVAsset,
                       track: AVAssetTrack,
                       now: CFAbsoluteTime,
                       codec: Codec) async throws -> (RandomAccessResult, Int) {
        let key = current.key

        if let until = quarantineUntil[key], now < until,
           let previous = try await prevRandomAccessStrict(from: key,
                                                          asset: asset,
                                                          track: track) {
            let preroll = codec == .hevc ? 6 : 4
            return (previous, preroll)
        }

        let failures = failCountValue(for: key)
        if failures >= 1,
           let previous = try await prevRandomAccessStrict(from: key,
                                                          asset: asset,
                                                          track: track) {
            quarantineUntil[key] = now + 0.5
            resetFail(for: key)
            let preroll = codec == .hevc ? 6 : 4
            return (previous, preroll)
        }

        let basePreroll = codec == .hevc ? 4 : 3
        return (current, basePreroll)
    }

    func prevRandomAccess(from key: RAKey,
                          asset: AVAsset,
                          track: AVAssetTrack) async throws -> RandomAccessResult? {
        guard let currentAbs = absTimeByKey[key] else { return nil }
        let trackKey = trackStreamKey(for: key)
        if let prevKey = prevSyncBefore(trackKey: trackKey, absMs: currentAbs),
           let prevResult = raResultsByKey[prevKey] {
            return prevResult
        }

        let margin: TimeInterval = max(Double(currentAbs) / 1000.0 - 0.001, 0)
        guard let previous = try await previousRandomAccess(before: margin,
                                                            asset: asset,
                                                            track: track) else {
            return nil
        }
        storeRandomAccess(previous)
        if let prevKey = prevSyncBefore(trackKey: trackKey, absMs: currentAbs),
           let prevResult = raResultsByKey[prevKey] {
            return prevResult
        }
        return nil
    }

    /// Legacy convenience wrapper returning only the PTS.
    func findIDR(near time: TimeInterval, asset: AVAsset, track: AVAssetTrack) async throws -> TimeInterval {
        let ra = try await findRandomAccess(near: time, asset: asset, track: track)
        return ra.pts
    }
    
    /// Analyzes GOP structure starting from an IDR frame.
    func analyzeGOP(starting idrPTS: TimeInterval, asset: AVAsset, track: AVAssetTrack) async throws -> GOPInfo {
        let cacheKey = gopCacheKey(for: track, streamID: 0, idrPTS: idrPTS)
        if let cached = gopCache[cacheKey], cached.isValid {
            return cached
        }

        do {
            let info = try await performGOPAnalysis(starting: idrPTS, asset: asset, track: track)
            gopCache[cacheKey] = info
            return info
        } catch {
            print("[GOPAnalyzer] GOP analysis failed, using fallback: \(error)")
            let fallbackInfo = GOPInfo(
                idrPTS: idrPTS,
                nextIDRPTS: idrPTS + fallbackWindowSize,
                frameCount: 24,  // Assume 24 frames at 24fps = 1 second
                timestamp: CFAbsoluteTimeGetCurrent()
            )
            gopCache[cacheKey] = fallbackInfo
            return fallbackInfo
        }
    }
    
    func clearCache() {
        gopCache.removeAll()
        raResultsByKey.removeAll()
        failCount.removeAll()
        failureLRU.removeAll()
        quarantineUntil.removeAll()
        recordsByTrack.removeAll()
        keyByTimestamp.removeAll()
        absTimeByKey.removeAll()
        prevCache.clear()
        nearestCache.clear()
    }

    func failCountForKey(_ key: RAKey) -> Int {
        failCountValue(for: key)
    }

    // MARK: - Private Methods

    private func failCountValue(for key: RAKey) -> Int {
        pruneFailures()
        return failCount[key]?.count ?? 0
    }

    private func touchFailureLRU(_ key: RAKey) {
        failureLRU.removeAll { $0 == key }
        failureLRU.append(key)
        pruneFailures()
        if failureLRU.count > failureCapacity {
            let overflow = failureLRU.count - failureCapacity
            for _ in 0..<overflow {
                if let oldest = failureLRU.first {
                    failureLRU.removeFirst()
                    failCount[oldest] = nil
                }
            }
        }
    }

    private func pruneFailures() {
        let now = CFAbsoluteTimeGetCurrent()
        failureLRU.removeAll { key in
            guard let entry = failCount[key] else { return true }
            if now > entry.expiresAt {
                failCount[key] = nil
                return true
            }
            return false
        }
    }
    
    private func findCachedIDR(near time: TimeInterval, track: AVAssetTrack) -> TimeInterval? {
        var closestIDR: TimeInterval?
        var closestDistance = Double.infinity
        let trackID = track.trackID
        let trackObjectID = ObjectIdentifier(track)

        for (key, info) in gopCache where info.isValid && key.trackObjectID == trackObjectID && key.trackID == trackID {
            let distance = abs(key.idrPTS - time)
            if distance < closestDistance {
                closestDistance = distance
                closestIDR = key.idrPTS
            }
        }

        if let idr = closestIDR, closestDistance < 2.0 {
            return idr
        }

        return nil
    }

    private func searchForRandomAccess(near time: TimeInterval,
                                       asset: AVAsset,
                                       track: AVAssetTrack) async throws -> RandomAccessResult {
        let searchRadius: TimeInterval = 2.0
        let start = max(0, time - searchRadius)
        let duration = searchRadius * 2
        
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        
        guard reader.canAdd(output) else {
            throw NSError(domain: "GOPAnalyzer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }
        
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "GOPAnalyzer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }
        
        typealias CandidateBucket = (result: RandomAccessResult, delta: TimeInterval)
        var bestBefore: CandidateBucket?
        var bestAfter: CandidateBucket?
        var bestBeforePartial: CandidateBucket?
        var bestAfterPartial: CandidateBucket?
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let flags = extractFlags(from: attachmentsArray)
            let kind = classifyRandomAccess(flags: flags)
            guard kind != .none else { continue }
            
            let requiresPreroll = (kind != .idr && kind != .none)
            let decodeTime = decodeTimestamp(for: sampleBuffer)
            let key = resolveKey(for: track, idrDTS: decodeTime)
            let candidate = RandomAccessResult(
                pts: pts,
                key: key,
                kind: kind,
                flags: flags,
                isFallback: false,
                requiresPreroll: requiresPreroll
            )
            storeRandomAccess(candidate)
            let delta = abs(time - pts)
            
            if pts <= time {
                if kind == .partial {
                    if bestBeforePartial == nil || delta < bestBeforePartial!.delta {
                        bestBeforePartial = (candidate, delta)
                    }
                } else if bestBefore == nil || delta < bestBefore!.delta {
                    bestBefore = (candidate, delta)
                }
            } else {
                if kind == .partial {
                    if bestAfterPartial == nil || delta < bestAfterPartial!.delta {
                        bestAfterPartial = (candidate, delta)
                    }
                } else if bestAfter == nil || delta < bestAfter!.delta {
                    bestAfter = (candidate, delta)
                }
            }
        }
        
        if let before = bestBefore {
            return before.result
        }
        let maxFutureDistance: TimeInterval = 0.5
        if let after = bestAfter, after.delta <= maxFutureDistance {
            return after.result
        }
        if let partialBefore = bestBeforePartial {
            return partialBefore.result
        }
        if let partialAfter = bestAfterPartial, partialAfter.delta <= maxFutureDistance {
            return partialAfter.result
        }
        
        let idrDTS = CMTime(seconds: time, preferredTimescale: 1000)
        let key = resolveKey(for: track, idrDTS: idrDTS)
        let fallback = RandomAccessResult(
            pts: time,
            key: key,
            kind: .none,
            flags: RandomAccessFlags(attachmentsPresent: false,
                                      notSync: nil,
                                      dependsOnOthers: nil,
                                      randomAccess: nil,
                                      noTemporalReference: nil,
                                      partialSync: nil,
                                      isDependedOnByOthers: nil),
            isFallback: true,
            requiresPreroll: false
        )
        storeRandomAccess(fallback)
        return fallback
    }
    
    private func performGOPAnalysis(starting idrPTS: TimeInterval,
                                    asset: AVAsset,
                                    track: AVAssetTrack) async throws -> GOPInfo {
        let maxGOPDuration: TimeInterval = 5.0
        
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: idrPTS, preferredTimescale: 600),
            duration: CMTime(seconds: maxGOPDuration, preferredTimescale: 600)
        )
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        
        guard reader.canAdd(output) else {
            throw NSError(domain: "GOPAnalyzer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }
        
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "GOPAnalyzer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }
        
        var frameCount = 0
        var nextIDRPTS: TimeInterval?
        var foundFirstRandomAccess = false
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if pts < idrPTS {
                continue
            }
            
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let flags = extractFlags(from: attachmentsArray)
            let kind = classifyRandomAccess(flags: flags)
            
            if kind != .none {
                if !foundFirstRandomAccess {
                    foundFirstRandomAccess = true
                } else {
                    nextIDRPTS = pts
                    break
                }
            }
            
            if foundFirstRandomAccess {
                frameCount += 1
            }
        }
        
        return GOPInfo(
            idrPTS: idrPTS,
            nextIDRPTS: nextIDRPTS,
            frameCount: frameCount,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }
    
    private func extractFlags(from attachmentsArray: [[CFString: Any]]?) -> RandomAccessFlags {
        guard let attachments = attachmentsArray?.first else {
            return RandomAccessFlags(attachmentsPresent: false,
                                     notSync: nil,
                                     dependsOnOthers: nil,
                                     randomAccess: nil,
                                     noTemporalReference: nil,
                                     partialSync: nil,
                                     isDependedOnByOthers: nil)
        }
        
        func boolValue(_ key: CFString) -> Bool? {
            guard let value = attachments[key] else { return nil }
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            let cfValue = value as CFTypeRef
            if CFGetTypeID(cfValue) == CFBooleanGetTypeID() {
                return CFBooleanGetValue(cfValue as! CFBoolean)
            }
            return nil
        }
        
        let randomAccessKey: CFString = "RandomAccess" as CFString
        let noTemporalReferenceKey: CFString = "DoesNotRequireTemporalReference" as CFString
        let partialSyncKey: CFString = "PartialSync" as CFString
        
        return RandomAccessFlags(
            attachmentsPresent: true,
            notSync: boolValue(kCMSampleAttachmentKey_NotSync),
            dependsOnOthers: boolValue(kCMSampleAttachmentKey_DependsOnOthers),
            randomAccess: boolValue(randomAccessKey),
            noTemporalReference: boolValue(noTemporalReferenceKey),
            partialSync: boolValue(partialSyncKey),
            isDependedOnByOthers: boolValue(kCMSampleAttachmentKey_IsDependedOnByOthers)
        )
    }

    private func classifyRandomAccess(flags: RandomAccessFlags) -> RandomAccessKind {
        if flags.dependsOnOthers == true {
            return .none
        }
        
        if flags.notSync == true {
            return .none
        }
        
        if flags.partialSync == true {
            return .partial
        }
        
        if flags.randomAccess == true {
            return .cra
        }
        
        if flags.noTemporalReference == true {
            return .bla
        }
        
        if let notSync = flags.notSync, notSync == false {
            return .idr
        }
        
        if !flags.attachmentsPresent {
            // stss-only sync sample; treat as IDR but note lack of metadata
            return .idr
        }
        
        return .none
    }
}

extension GOPAnalyzer {
    func previousRandomAccess(before time: TimeInterval,
                              asset: AVAsset,
                              track: AVAssetTrack) async throws -> RandomAccessResult? {
        let searchRadius: TimeInterval = 4.0
        let start = max(0, time - searchRadius)
        let duration = min(searchRadius, time) + 0.25

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(domain: "GOPAnalyzer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add track output"])
        }

        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "GOPAnalyzer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        var candidate: RandomAccessResult?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if pts >= time { break }
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let flags = extractFlags(from: attachmentsArray)
            let kind = classifyRandomAccess(flags: flags)
            guard kind != .none else { continue }
            let requiresPreroll = (kind != .idr && kind != .none)
            let decodeTime = decodeTimestamp(for: sampleBuffer)
            let key = resolveKey(for: track, idrDTS: decodeTime)
            let result = RandomAccessResult(pts: pts,
                                            key: key,
                                            kind: kind,
                                            flags: flags,
                                            isFallback: false,
                                            requiresPreroll: requiresPreroll)
            storeRandomAccess(result)
            candidate = result
        }

        return candidate
    }
}
