import CoreVideo

/// Maintains a byte-budgeted, time-sorted set of "safe" frames per clip.
/// Frames closest to the active anchor (predicted timeline position) are retained,
/// while older or distant frames are evicted first once the budget is exceeded.
@MainActor(unsafe)
final class FrameHistoryManager {
    enum Source {
        case playback
        case scrub
    }
    
    private struct Entry {
        let time: TimeInterval
        let buffer: CVPixelBuffer
        let version: UInt64?
        let source: Source
        let byteSize: Int
        var lastAccess: CFAbsoluteTime
    }
    
    private let byteBudget: Int
    private let maxAge: TimeInterval
    private let biasWindow: TimeInterval
    private let scrubPriorityBoost: Double
    private let byteWeight: Double
    private var entries: [Entry] = []
    private var currentBytes: Int = 0

    var isEmpty: Bool { entries.isEmpty }
    
    init(byteBudget: Int,
         maxAge: TimeInterval,
         biasWindow: TimeInterval,
         scrubPriorityBoost: Double = 0,
         byteWeight: Double = 0) {
        self.byteBudget = max(byteBudget, 0)
        self.maxAge = max(maxAge, 0)
        self.biasWindow = max(biasWindow, 0)
        self.scrubPriorityBoost = max(scrubPriorityBoost, 0)
        self.byteWeight = max(byteWeight, 0)
    }
    
    func clear() {
        entries.removeAll(keepingCapacity: true)
        currentBytes = 0
    }
    
    func record(buffer: CVPixelBuffer,
                time: TimeInterval,
                version: UInt64?,
                source: Source,
                anchor: TimeInterval) {
        let now = CFAbsoluteTimeGetCurrent()
        pruneExpired(anchor: anchor, now: now)
        let byteSize = FrameHistoryManager.estimateSize(of: buffer)
        let entry = Entry(time: time,
                          buffer: buffer,
                          version: version,
                          source: source,
                          byteSize: byteSize,
                          lastAccess: now)
        entries.append(entry)
        entries.sort { $0.time < $1.time }
        currentBytes += byteSize
        trimToBudget(anchor: anchor, now: now)
    }
    
    func prune(keepingNear anchor: TimeInterval) {
        let now = CFAbsoluteTimeGetCurrent()
        pruneExpired(anchor: anchor, now: now)
        trimToBudget(anchor: anchor, now: now)
    }
    
    func bestFrame(around time: TimeInterval,
                   preferredVersion: UInt64? = nil) -> (buffer: CVPixelBuffer, time: TimeInterval, version: UInt64?, source: Source)? {
        let now = CFAbsoluteTimeGetCurrent()
        if let preferredVersion,
           let index = bestEntryIndex(around: time, validator: { entry in
               guard let version = entry.version else { return true }
               return version == preferredVersion
           }) {
            entries[index].lastAccess = now
            return (entries[index].buffer, entries[index].time, entries[index].version, entries[index].source)
        }
        
        if let index = bestEntryIndex(around: time, validator: { $0.version == nil }) {
            entries[index].lastAccess = now
            return (entries[index].buffer, entries[index].time, entries[index].version, entries[index].source)
        }
        
        if let index = bestEntryIndex(around: time, validator: { _ in true }) {
            entries[index].lastAccess = now
            return (entries[index].buffer, entries[index].time, entries[index].version, entries[index].source)
        }
        
        return nil
    }
    
    func latest() -> (buffer: CVPixelBuffer, time: TimeInterval, version: UInt64?, source: Source)? {
        guard let last = entries.last else { return nil }
        entries[entries.count - 1].lastAccess = CFAbsoluteTimeGetCurrent()
        return (last.buffer, last.time, last.version, last.source)
    }

    func count(in range: ClosedRange<TimeInterval>) -> Int {
        entries.reduce(0) { count, entry in
            range.contains(entry.time) ? count + 1 : count
        }
    }

    func contains(time: TimeInterval, tolerance: TimeInterval) -> Bool {
        let epsilon = max(tolerance, 1e-6)
        return entries.contains { abs($0.time - time) <= epsilon }
    }

    func frame(at time: TimeInterval, tolerance: TimeInterval) -> (buffer: CVPixelBuffer, time: TimeInterval)? {
        let epsilon = max(tolerance, 1e-6)
        for (index, entry) in entries.enumerated() {
            if abs(entry.time - time) <= epsilon {
                entries[index].lastAccess = CFAbsoluteTimeGetCurrent()
                return (entry.buffer, entry.time)
            }
        }
        return nil
    }

    func times(in range: ClosedRange<TimeInterval>) -> [TimeInterval] {
        entries.compactMap { range.contains($0.time) ? $0.time : nil }
    }

    @discardableResult
    func remove(before cutoff: TimeInterval) -> Int {
        var removedBytes = 0
        var removedCount = 0
        entries.removeAll { entry in
            if entry.time < cutoff {
                removedBytes += entry.byteSize
                removedCount += 1
                return true
            }
            return false
        }
        currentBytes = max(currentBytes - removedBytes, 0)
        return removedCount
    }

    @discardableResult
    func remove(after cutoff: TimeInterval) -> Int {
        var removedBytes = 0
        var removedCount = 0
        entries.removeAll { entry in
            if entry.time > cutoff {
                removedBytes += entry.byteSize
                removedCount += 1
                return true
            }
            return false
        }
        currentBytes = max(currentBytes - removedBytes, 0)
        return removedCount
    }
    
    // MARK: - Budget Management
    
    private func pruneExpired(anchor: TimeInterval, now: CFAbsoluteTime) {
        guard maxAge > 0 else { return }
        let lowerBound = anchor - maxAge
        var removedBytes = 0
        entries.removeAll { entry in
            if entry.time < lowerBound {
                removedBytes += entry.byteSize
                return true
            }
            return false
        }
        currentBytes = max(currentBytes - removedBytes, 0)
    }
    
    private func trimToBudget(anchor: TimeInterval, now: CFAbsoluteTime) {
        guard byteBudget > 0 else { return }
        while currentBytes > byteBudget, let index = removalCandidateIndex(anchor: anchor, now: now) {
            currentBytes -= entries[index].byteSize
            entries.remove(at: index)
        }
    }
    
    private func removalCandidateIndex(anchor: TimeInterval, now: CFAbsoluteTime) -> Int? {
        guard !entries.isEmpty else { return nil }
        var bestIndex = 0
        var bestScore = -Double.infinity
        for (index, entry) in entries.enumerated() {
            let distance = abs(entry.time - anchor)
            let outsideBias = max(distance - biasWindow, 0)
            let staleness = now - entry.lastAccess
            // Weight distance higher so we bias around anchor, break ties with LRU and byte size
            var score = (outsideBias * 1000.0) + staleness
            if byteWeight > 0 {
                score += Double(entry.byteSize) * byteWeight
            }
            if scrubPriorityBoost > 0, entry.source == .scrub {
                score -= scrubPriorityBoost
            }
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }
    
    private func bestEntryIndex(around time: TimeInterval,
                                validator: (Entry) -> Bool) -> Int? {
        var bestPastIndex: Int?
        var bestFutureIndex: Int?
        var bestPastDelta = Double.greatestFiniteMagnitude
        var bestFutureDelta = Double.greatestFiniteMagnitude
        
        for (index, entry) in entries.enumerated() where validator(entry) {
            let delta = entry.time - time
            if delta <= 0 {
                let magnitude = abs(delta)
                if magnitude < bestPastDelta {
                    bestPastDelta = magnitude
                    bestPastIndex = index
                }
            } else if delta < bestFutureDelta {
                bestFutureDelta = delta
                bestFutureIndex = index
            }
        }
        
        if let past = bestPastIndex {
            return past
        }
        return bestFutureIndex
    }
    
    private static func estimateSize(of buffer: CVPixelBuffer) -> Int {
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount == 0 {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            return bytesPerRow * height
        }
        var total = 0
        for plane in 0..<planeCount {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            total += bytesPerRow * height
        }
        return total
    }
}
