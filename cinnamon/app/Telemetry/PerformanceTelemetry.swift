import Foundation
import os.signpost
import CoreVideo

/// Performance telemetry system using os_signpost for Instruments integration
/// Tracks all critical paths in the scrubbing and rendering pipeline
@MainActor
final class PerformanceTelemetry {

    // MARK: - OSLog Categories

    private let scrubLog = OSLog(subsystem: "com.cinnamon.performance", category: "Scrub")
    private let decodeLog = OSLog(subsystem: "com.cinnamon.performance", category: "Decode")
    private let renderLog = OSLog(subsystem: "com.cinnamon.performance", category: "Render")
    private let cacheLog = OSLog(subsystem: "com.cinnamon.performance", category: "Cache")
    private let gpuLog = OSLog(subsystem: "com.cinnamon.performance", category: "GPU")
    private let proxyLog = OSLog(subsystem: "com.cinnamon.performance", category: "Proxy")

    // MARK: - Signpost IDs

    private var activeSignposts: [String: OSSignpostID] = [:]
    private let signpostLock = NSLock()

    // MARK: - Types

    struct ScrubMetrics {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let direction: String
        let velocity: Double
        let framesDecoded: Int
        let cacheHitRate: Double
        let averageLatency: TimeInterval
    }

    struct DecodeMetrics {
        let clipID: String
        let pts: TimeInterval
        let duration: TimeInterval
        let codecType: String
        let frameType: String
        let prerollFrames: Int
        let success: Bool
    }

    struct RenderMetrics {
        let passName: String
        let duration: TimeInterval
        let pixelCount: Int
        let layerCount: Int
        let effectCount: Int
    }

    struct CacheMetrics {
        let hitRate: Double
        let ramUsageMB: Double
        let diskUsageMB: Double
        let evictionCount: Int
    }

    // MARK: - Singleton

    static let shared = PerformanceTelemetry()

    private init() {
        setupNotifications()
    }

    // MARK: - Scrubbing Telemetry

    func beginScrub(clipID: UUID, direction: String, velocity: Double) -> OSSignpostID {
        let signpostID = OSSignpostID(log: scrubLog)

        os_signpost(.begin,
                   log: scrubLog,
                   name: "Scrub",
                   signpostID: signpostID,
                   "clip:%{public}s dir:%{public}s vel:%.2f",
                   String(clipID.uuidString.prefix(8)), direction, velocity)

        signpostLock.lock()
        activeSignposts["scrub_\(clipID)"] = signpostID
        signpostLock.unlock()

        return signpostID
    }

    func updateScrub(clipID: UUID, position: TimeInterval, velocity: Double) {
        signpostLock.lock()
        let signpostID = activeSignposts["scrub_\(clipID)"] ?? OSSignpostID(log: scrubLog)
        signpostLock.unlock()

        os_signpost(.event,
                   log: scrubLog,
                   name: "ScrubUpdate",
                   signpostID: signpostID,
                   "pos:%.3f vel:%.2f",
                   position, velocity)
    }

    func endScrub(clipID: UUID, metrics: ScrubMetrics) {
        signpostLock.lock()
        let signpostID = activeSignposts.removeValue(forKey: "scrub_\(clipID)") ?? OSSignpostID(log: scrubLog)
        signpostLock.unlock()

        os_signpost(.end,
                   log: scrubLog,
                   name: "Scrub",
                   signpostID: signpostID,
                   "frames:%d hitRate:%.2f avgLatency:%.3f",
                   metrics.framesDecoded, metrics.cacheHitRate, metrics.averageLatency)
    }

    // MARK: - Decode Telemetry

    func beginDecode(clipID: UUID, pts: TimeInterval, codecType: String) -> OSSignpostID {
        let signpostID = OSSignpostID(log: decodeLog)

        os_signpost(.begin,
                   log: decodeLog,
                   name: "Decode",
                   signpostID: signpostID,
                   "clip:%{public}s pts:%.3f codec:%{public}s",
                   String(clipID.uuidString.prefix(8)), pts, codecType)

        return signpostID
    }

    func markDecodeStage(_ stage: String, signpostID: OSSignpostID, duration: TimeInterval) {
        os_signpost(.event,
                   log: decodeLog,
                   name: "DecodeStage",
                   signpostID: signpostID,
                   "stage:%{public}s duration:%.3f",
                   stage, duration * 1000) // Convert to ms
    }

    func endDecode(signpostID: OSSignpostID, metrics: DecodeMetrics) {
        os_signpost(.end,
                   log: decodeLog,
                   name: "Decode",
                   signpostID: signpostID,
                   "duration:%.3f frameType:%{public}s success:%d",
                   metrics.duration * 1000, metrics.frameType, metrics.success ? 1 : 0)
    }

    // MARK: - Render Telemetry

    func beginRenderPass(_ passName: String) -> OSSignpostID {
        let signpostID = OSSignpostID(log: renderLog)

        os_signpost(.begin,
                   log: renderLog,
                   name: "RenderPass",
                   signpostID: signpostID,
                   "pass:%{public}s",
                   passName)

        return signpostID
    }

    func markRenderStage(_ stage: String, signpostID: OSSignpostID) {
        os_signpost(.event,
                   log: renderLog,
                   name: "RenderStage",
                   signpostID: signpostID,
                   "stage:%{public}s",
                   stage)
    }

    func endRenderPass(signpostID: OSSignpostID, metrics: RenderMetrics) {
        os_signpost(.end,
                   log: renderLog,
                   name: "RenderPass",
                   signpostID: signpostID,
                   "duration:%.3f pixels:%d layers:%d effects:%d",
                   metrics.duration * 1000, metrics.pixelCount, metrics.layerCount, metrics.effectCount)
    }

    // MARK: - Cache Telemetry

    func logCacheHit(level: String, key: String) {
        os_signpost(.event,
                   log: cacheLog,
                   name: "CacheHit",
                   "level:%{public}s key:%{public}s",
                   level, String(key.prefix(20)))
    }

    func logCacheMiss(key: String, willDecode: Bool) {
        os_signpost(.event,
                   log: cacheLog,
                   name: "CacheMiss",
                   "key:%{public}s willDecode:%d",
                   String(key.prefix(20)), willDecode ? 1 : 0)
    }

    func logCacheEviction(count: Int, freedMB: Double, reason: String) {
        os_signpost(.event,
                   log: cacheLog,
                   name: "CacheEviction",
                   "count:%d freedMB:%.2f reason:%{public}s",
                   count, freedMB, reason)
    }

    func logCacheStats(_ metrics: CacheMetrics) {
        os_signpost(.event,
                   log: cacheLog,
                   name: "CacheStats",
                   "hitRate:%.2f ramMB:%.2f diskMB:%.2f evictions:%d",
                   metrics.hitRate, metrics.ramUsageMB, metrics.diskUsageMB, metrics.evictionCount)
    }

    // MARK: - GPU Telemetry

    func beginGPUWork(_ workType: String) -> OSSignpostID {
        let signpostID = OSSignpostID(log: gpuLog)

        os_signpost(.begin,
                   log: gpuLog,
                   name: "GPUWork",
                   signpostID: signpostID,
                   "type:%{public}s",
                   workType)

        return signpostID
    }

    func markGPUEvent(_ event: String, signpostID: OSSignpostID, value: Double? = nil) {
        if let value = value {
            os_signpost(.event,
                       log: gpuLog,
                       name: "GPUEvent",
                       signpostID: signpostID,
                       "event:%{public}s value:%.3f",
                       event, value)
        } else {
            os_signpost(.event,
                       log: gpuLog,
                       name: "GPUEvent",
                       signpostID: signpostID,
                       "event:%{public}s",
                       event)
        }
    }

    func endGPUWork(signpostID: OSSignpostID, duration: TimeInterval, bandwidth: Double? = nil) {
        if let bandwidth = bandwidth {
            os_signpost(.end,
                       log: gpuLog,
                       name: "GPUWork",
                       signpostID: signpostID,
                       "duration:%.3f bandwidthMB:%.2f",
                       duration * 1000, bandwidth)
        } else {
            os_signpost(.end,
                       log: gpuLog,
                       name: "GPUWork",
                       signpostID: signpostID,
                       "duration:%.3f",
                       duration * 1000)
        }
    }

    // MARK: - Proxy Telemetry

    func logProxyTrigger(clipID: UUID, reason: String, targetMS: Int64) {
        os_signpost(.event,
                   log: proxyLog,
                   name: "ProxyTrigger",
                   "clip:%{public}s reason:%{public}s targetMS:%lld",
                   String(clipID.uuidString.prefix(8)), reason, targetMS)
    }

    func logProxyHit(clipID: UUID, zoneID: UUID, context: String) {
        os_signpost(.event,
                   log: proxyLog,
                   name: "ProxyHit",
                   "clip:%{public}s zone:%{public}s context:%{public}s",
                   String(clipID.uuidString.prefix(8)), String(zoneID.uuidString.prefix(8)), context)
    }

    func logProxyMiss(clipID: UUID, reason: String) {
        os_signpost(.event,
                   log: proxyLog,
                   name: "ProxyMiss",
                   "clip:%{public}s reason:%{public}s",
                   String(clipID.uuidString.prefix(8)), reason)
    }

    func beginProxyExport(clipID: UUID, durationMS: Int64) -> OSSignpostID {
        let signpostID = OSSignpostID(log: proxyLog)

        os_signpost(.begin,
                   log: proxyLog,
                   name: "ProxyExport",
                   signpostID: signpostID,
                   "clip:%{public}s durationMS:%lld",
                   String(clipID.uuidString.prefix(8)), durationMS)

        return signpostID
    }

    func endProxyExport(signpostID: OSSignpostID, success: Bool, exportTimeMS: Double) {
        os_signpost(.end,
                   log: proxyLog,
                   name: "ProxyExport",
                   signpostID: signpostID,
                   "success:%d exportTimeMS:%.2f",
                   success ? 1 : 0, exportTimeMS)
    }

    // MARK: - Frame Pipeline Telemetry

    func logFrameDelivery(clipID: UUID, pts: TimeInterval, latencyMS: Double, source: String) {
        os_signpost(.event,
                   log: scrubLog,
                   name: "FrameDelivery",
                   "clip:%{public}s pts:%.3f latencyMS:%.2f source:%{public}s",
                   String(clipID.uuidString.prefix(8)), pts, latencyMS, source)
    }

    func logLandingZone(targetPTS: TimeInterval, windowStart: TimeInterval, windowEnd: TimeInterval, warmFrames: Int) {
        os_signpost(.event,
                   log: scrubLog,
                   name: "LandingZone",
                   "target:%.3f window:[%.3f,%.3f] warm:%d",
                   targetPTS, windowStart, windowEnd, warmFrames)
    }

    func logAdmissionControl(clipID: UUID, admitted: Bool, reason: String, queueDepth: Int) {
        os_signpost(.event,
                   log: decodeLog,
                   name: "AdmissionControl",
                   "clip:%{public}s admitted:%d reason:%{public}s depth:%d",
                   String(clipID.uuidString.prefix(8)), admitted ? 1 : 0, reason, queueDepth)
    }

    // MARK: - Performance Points

    func measureBlock<T>(_ name: String, log: OSLog? = nil, block: () throws -> T) rethrows -> T {
        let targetLog = log ?? scrubLog
        let signpostID = OSSignpostID(log: targetLog)

        os_signpost(.begin, log: targetLog, name: "MeasureBlock", signpostID: signpostID,
                   "name:%{public}s", name)

        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            os_signpost(.end, log: targetLog, name: "MeasureBlock", signpostID: signpostID,
                       "name:%{public}s durationMS:%.3f", name, duration)
        }

        return try block()
    }

    func measureAsyncBlock<T>(_ name: String, log: OSLog? = nil, block: () async throws -> T) async rethrows -> T {
        let targetLog = log ?? scrubLog
        let signpostID = OSSignpostID(log: targetLog)

        os_signpost(.begin, log: targetLog, name: "MeasureAsyncBlock", signpostID: signpostID,
                   "name:%{public}s", name)

        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            os_signpost(.end, log: targetLog, name: "MeasureAsyncBlock", signpostID: signpostID,
                       "name:%{public}s durationMS:%.3f", name, duration)
        }

        return try await block()
    }

    // MARK: - System Monitoring

    func logMemoryPressure(level: String, availableMB: Double) {
        os_signpost(.event,
                   log: scrubLog,
                   name: "MemoryPressure",
                   "level:%{public}s availableMB:%.2f",
                   level, availableMB)
    }

    func logThermalState(_ state: ProcessInfo.ThermalState) {
        let stateString: String
        switch state {
        case .nominal:
            stateString = "nominal"
        case .fair:
            stateString = "fair"
        case .serious:
            stateString = "serious"
        case .critical:
            stateString = "critical"
        @unknown default:
            stateString = "unknown"
        }

        os_signpost(.event,
                   log: scrubLog,
                   name: "ThermalState",
                   "state:%{public}s",
                   stateString)
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        // Monitor thermal state changes
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.logThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
    }
}

// MARK: - Convenience Extensions

extension PerformanceTelemetry {
    /// Quick performance measurement for closures
    func measure<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
        return try measureBlock(label, block: block)
    }

    /// Quick async performance measurement
    func measureAsync<T>(_ label: String, _ block: () async throws -> T) async rethrows -> T {
        return try await measureAsyncBlock(label, block: block)
    }
}