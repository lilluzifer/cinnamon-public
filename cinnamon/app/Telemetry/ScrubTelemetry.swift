import Foundation

/// Centralized telemetry system for scrub operations.
/// Collects detailed logs for diagnostics and performance analysis.
@MainActor
final class ScrubTelemetry {
    static let shared = ScrubTelemetry()
    
    // MARK: - Log Types
    
    struct ScrubLog {
        let timestamp: CFAbsoluteTime
        let state: ScrubCoordinator.ScrubState
        let direction: ScrubCoordinator.ScrubDirection
        let velocityFPS: Double
        let epoch: UInt64
    }
    
    struct HistoryCheckLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let time: TimeInterval
        let hit: Bool
        let ringFillPercent: Double
    }
    
    struct CoalesceLog {
        let timestamp: CFAbsoluteTime
        let minIntervalMS: Double
        let sinceLastMS: Double
        let decision: String  // "start" or "skip"
        let equalityFix: Bool  // true if using >=
    }
    
    struct GOPCoalesceLog {
        let timestamp: CFAbsoluteTime
        let gopKey: TimeInterval
        let reused: Bool
        let retarget: Bool
        let canceled: Bool
    }
    
    struct ReverseLZLog {
        let timestamp: CFAbsoluteTime
        let tNow: TimeInterval
        let tPred: TimeInterval
        let warmBehind: Int
        let warmAhead: Int
        let repairActive: Bool
        let repairFrames: Int
    }
    
    struct DecodeLog {
        let timestamp: CFAbsoluteTime
        let pts: TimeInterval
        let durationMS: Double
        let reason: String  // "lz", "gop", "deadline"
        let epoch: UInt64
    }
    
    struct RingLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let fillPercent: Double
        let inflight: Int
        let cancels: Int
        let hits: Int
        let misses: Int
    }
    
    struct StopMetricLog {
        let timestamp: CFAbsoluteTime
        let direction: ScrubCoordinator.ScrubDirection
        let timeToExactFrameMS: Double
    }
    
    // Phase 3 logs
    struct ScrubReaderLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let windowStart: TimeInterval
        let windowEnd: TimeInterval
        let shifts: Int
        let rebuilds: Int
        let durationMS: Double
    }
    
    struct VTSessionLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let created: Int
        let reused: Int
        let asyncEnabled: Bool
        let durationMS: Double
    }
    
    struct DecodeStagesLog {
        let timestamp: CFAbsoluteTime
        let pts: TimeInterval
        let initMS: Double
        let seekIDRMS: Double
        let prerollMS: Double
        let firstSampleMS: Double
        let decodeMS: Double
        let convertMS: Double
        let cacheWriteMS: Double
    }
    
    struct PoolLog {
        let timestamp: CFAbsoluteTime
        let warmedBuffers: Int
        let hits: Int
        let misses: Int
    }
    
    // Phase 2 logs
    struct PredictionLog {
        let timestamp: CFAbsoluteTime
        let tNow: TimeInterval
        let tPred: TimeInterval
        let velocityFPS: Double
        var windowFrames: Int = 0  // Default for backward compatibility
    }
    
    struct AdmissionLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let clipInflight: Int
        let globalInflight: Int
        let denied: Bool
        let reason: String
        let kind: String
        let criticalUsed: Bool
    }

    struct DecodeAttemptLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let attempt: Int
        let hash: String
        let duplicate: Bool
    }

    struct DecodeFailureLog {
        let timestamp: CFAbsoluteTime
        let clipID: UUID
        let status: String
        let attempt: Int
        let anchor: TimeInterval
        let leadFrames: Int
        let nextAction: String
    }
    
    struct RenderMetricsLog {
        let timestamp: CFAbsoluteTime
        let windowDuration: TimeInterval
        let dropped: Int
        let presentLatencyAvgMS: Double
        let presentLatencyP95MS: Double
    }

    struct TileRenderLog {
        let timestamp: CFAbsoluteTime
        let dirtyTileCount: Int
        let coverage: Double
        let fullFrame: Bool
    }
    
    // MARK: - Storage
    
    private var scrubLogs: [ScrubLog] = []
    private var historyCheckLogs: [HistoryCheckLog] = []
    private var coalesceLogs: [CoalesceLog] = []
    private var gopCoalesceLogs: [GOPCoalesceLog] = []
    private var reverseLZLogs: [ReverseLZLog] = []
    private var decodeLogs: [DecodeLog] = []
    private var ringLogs: [RingLog] = []
    private var stopMetricLogs: [StopMetricLog] = []
    
    // Phase 3 logs
    private var scrubReaderLogs: [ScrubReaderLog] = []
    private var vtSessionLogs: [VTSessionLog] = []
    private var decodeStagesLogs: [DecodeStagesLog] = []
    private var poolLogs: [PoolLog] = []
    
    // Phase 2 logs
    private var predictionLogs: [PredictionLog] = []
    private var admissionLogs: [AdmissionLog] = []
    private var decodeAttemptLogs: [DecodeAttemptLog] = []
    private var decodeFailureLogs: [DecodeFailureLog] = []
    private var renderMetricsLogs: [RenderMetricsLog] = []
    private var tileRenderLogs: [TileRenderLog] = []
    
    private let maxLogsPerType = 1000  // Limit memory usage
    
    private init() {}
    
    // MARK: - Logging Methods
    
    func logScrub(_ log: ScrubLog) {
        scrubLogs.append(log)
        trimIfNeeded(&scrubLogs)
        
        print("[SCRUB] state=\(log.state) dir=\(log.direction) velocity_fps=\(String(format: "%.1f", log.velocityFPS)) epoch=\(log.epoch)")
    }
    
    func logHistoryCheck(_ log: HistoryCheckLog) {
        historyCheckLogs.append(log)
        trimIfNeeded(&historyCheckLogs)
        
        let hitStr = log.hit ? "t" : "f"
        print("[HISTORY] check clip=\(log.clipID.uuidString.prefix(8)) t=\(String(format: "%.3f", log.time)) hit=\(hitStr) ringFill%=\(String(format: "%.1f", log.ringFillPercent * 100))")
    }
    
    func logCoalesce(_ log: CoalesceLog) {
        coalesceLogs.append(log)
        trimIfNeeded(&coalesceLogs)
        
        let eqFix = log.equalityFix ? ">=" : ">"
        print("[COALESCE] minInterval_ms=\(String(format: "%.1f", log.minIntervalMS)) sinceLast_ms=\(String(format: "%.1f", log.sinceLastMS)) decision=\(log.decision) eq_fix=\(eqFix)")
    }
    
    func logGOPCoalesce(_ log: GOPCoalesceLog) {
        gopCoalesceLogs.append(log)
        trimIfNeeded(&gopCoalesceLogs)
        
        let reusedStr = log.reused ? "t" : "f"
        let retargetStr = log.retarget ? "t" : "f"
        let canceledStr = log.canceled ? "t" : "f"
        print("[COALESCE_GOP] gopKey=IDR@\(String(format: "%.3f", log.gopKey)) reused=\(reusedStr) retarget=\(retargetStr) canceled=\(canceledStr)")
    }
    
    func logReverseLZ(_ log: ReverseLZLog) {
        reverseLZLogs.append(log)
        trimIfNeeded(&reverseLZLogs)

        let repairSuffix = log.repairActive ? " repair=\(log.repairFrames)" : ""
        print("[REV_LZ] t_now=\(String(format: "%.3f", log.tNow)) t_pred=\(String(format: "%.3f", log.tPred)) warmBehind=\(log.warmBehind) warmAhead=\(log.warmAhead)\(repairSuffix)")
    }
    
    func logDecode(_ log: DecodeLog) {
        decodeLogs.append(log)
        trimIfNeeded(&decodeLogs)
        
        print("[DECODE] pts=\(String(format: "%.3f", log.pts)) dur_ms=\(String(format: "%.1f", log.durationMS)) reason=\(log.reason) epoch=\(log.epoch)")
    }
    
    func logRing(_ log: RingLog) {
        ringLogs.append(log)
        trimIfNeeded(&ringLogs)
        
        print("[RING] clip=\(log.clipID.uuidString.prefix(8)) fill%=\(String(format: "%.1f", log.fillPercent * 100)) inflight=\(log.inflight) cancels=\(log.cancels) hits/misses=\(log.hits)/\(log.misses)")
    }
    
    func logStopMetric(_ log: StopMetricLog) {
        stopMetricLogs.append(log)
        trimIfNeeded(&stopMetricLogs)
        
        print("[STOP_METRIC] \(log.direction) time_to_exact_frame_ms=\(String(format: "%.1f", log.timeToExactFrameMS))")
    }
    
    // Phase 3 logging
    func logScrubReader(_ log: ScrubReaderLog) {
        scrubReaderLogs.append(log)
        trimIfNeeded(&scrubReaderLogs)
        
        print("[SCRUB_READER] window=[\(String(format: "%.3f", log.windowStart)),\(String(format: "%.3f", log.windowEnd))] shifts=\(log.shifts) rebuilds=\(log.rebuilds)")
    }
    
    func logVTSession(_ log: VTSessionLog) {
        vtSessionLogs.append(log)
        trimIfNeeded(&vtSessionLogs)
        
        let asyncStr = log.asyncEnabled ? "t" : "f"
        print("[VT] created=\(log.created) reused=\(log.reused) async=\(asyncStr)")
    }
    
    func logDecodeStages(_ log: DecodeStagesLog) {
        decodeStagesLogs.append(log)
        trimIfNeeded(&decodeStagesLogs)
        
        print("[SCRUB_DECODE] stages_ms {init=\(String(format: "%.1f", log.initMS)), seekIDR=\(String(format: "%.1f", log.seekIDRMS)), preroll=\(String(format: "%.1f", log.prerollMS)), firstSample=\(String(format: "%.1f", log.firstSampleMS)), decode=\(String(format: "%.1f", log.decodeMS)), convert=\(String(format: "%.1f", log.convertMS)), cacheWrite=\(String(format: "%.1f", log.cacheWriteMS))}")
    }
    
    func logPool(_ log: PoolLog) {
        poolLogs.append(log)
        trimIfNeeded(&poolLogs)
        
        print("[POOL] warmed_buffers=\(log.warmedBuffers) hits=\(log.hits) misses=\(log.misses)")
    }
    
    // Phase 2 logging
    func logPrediction(_ log: PredictionLog) {
        predictionLogs.append(log)
        trimIfNeeded(&predictionLogs)
        
        print("[PRED] t_now=\(String(format: "%.3f", log.tNow)) t_pred=\(String(format: "%.3f", log.tPred)) velocity_fps=\(String(format: "%.1f", log.velocityFPS)) window_frames=\(log.windowFrames)")
    }
    
    func logAdmission(_ log: AdmissionLog) {
        admissionLogs.append(log)
        trimIfNeeded(&admissionLogs)

        let status = log.denied ? "denied" : "granted"
        let critical = log.criticalUsed ? "t" : "f"
        print("[ADMISSION] \(status) kind=\(log.kind) criticalUsed=\(critical) clip=\(log.clipID.uuidString.prefix(8)) clip_inflight=\(log.clipInflight) global_inflight=\(log.globalInflight) reason=\(log.reason)")
    }

    func logWatchdog(timeoutMs: Double, action: String) {
        print("[WD] timeoutMs=\(String(format: "%.1f", timeoutMs)) action=\(action)")
    }

    func currentDecodeP95() -> Double? {
        guard !decodeLogs.isEmpty else { return nil }
        let sorted = decodeLogs.map { $0.durationMS }.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int(ceil(0.95 * Double(sorted.count))) - 1
        return sorted[max(0, min(rank, sorted.count - 1))]
    }

    func logMandatorySummary(successCount: Int, retries: Int) {
        print("[MANDATORY] successCount=\(successCount) retries=\(retries)")
    }

    func logDecodeAttempt(_ log: DecodeAttemptLog) {
        decodeAttemptLogs.append(log)
        trimIfNeeded(&decodeAttemptLogs)

        let duplicate = log.duplicate ? "true" : "false"
        print("[DEC_ATTEMPT] clip=\(log.clipID.uuidString.prefix(8)) attempt=\(log.attempt) hash=\(log.hash) duplicate=\(duplicate)")
    }

    func logDecodeFailure(_ log: DecodeFailureLog) {
        decodeFailureLogs.append(log)
        trimIfNeeded(&decodeFailureLogs)

        let anchorStr = String(format: "%.3f", log.anchor)
        print("[DEC_FAIL] status=\(log.status) attempt=\(log.attempt) anchor=\(anchorStr) bLead=\(log.leadFrames) next=\(log.nextAction)")
    }
    
    func logRenderMetrics(_ log: RenderMetricsLog) {
        renderMetricsLogs.append(log)
        trimIfNeeded(&renderMetricsLogs)
        
        print("[RENDER_1S] dropped=\(log.dropped) presentLatency_avg_ms=\(String(format: "%.1f", log.presentLatencyAvgMS)) p95_ms=\(String(format: "%.1f", log.presentLatencyP95MS))")
    }

    func logRenderTiles(_ log: TileRenderLog) {
        tileRenderLogs.append(log)
        trimIfNeeded(&tileRenderLogs)
        
        let coveragePct = String(format: "%.1f", log.coverage * 100)
        let fullFrame = log.fullFrame ? "t" : "f"
        print("[RENDER_TILES] dirty=\(log.dirtyTileCount) coverage%=\(coveragePct) full=\(fullFrame)")
    }

    
    // MARK: - Report Generation
    
    func generateReport() -> String {
        var report = "=== Scrub Telemetry Report ===\n\n"
        
        // Scrub state summary
        report += "Scrub States:\n"
        report += "  Total state changes: \(scrubLogs.count)\n"
        let fastCount = scrubLogs.filter { $0.state == .fast }.count
        let mediumCount = scrubLogs.filter { $0.state == .medium }.count
        let slowCount = scrubLogs.filter { $0.state == .slow }.count
        report += "  FAST: \(fastCount), MEDIUM: \(mediumCount), SLOW: \(slowCount)\n\n"
        
        // History check summary
        report += "History Checks:\n"
        report += "  Total checks: \(historyCheckLogs.count)\n"
        let hits = historyCheckLogs.filter { $0.hit }.count
        let hitRate = historyCheckLogs.isEmpty ? 0.0 : Double(hits) / Double(historyCheckLogs.count)
        report += "  Hit rate: \(String(format: "%.1f", hitRate * 100))%\n\n"
        
        // Coalesce summary
        report += "Rate-Gate Coalescing:\n"
        report += "  Total decisions: \(coalesceLogs.count)\n"
        let skips = coalesceLogs.filter { $0.decision == "skip" }.count
        report += "  Skipped: \(skips), Started: \(coalesceLogs.count - skips)\n\n"
        
        // GOP coalesce summary
        report += "GOP Coalescing:\n"
        report += "  Total GOP operations: \(gopCoalesceLogs.count)\n"
        let reused = gopCoalesceLogs.filter { $0.reused }.count
        let gopReuseRate = gopCoalesceLogs.isEmpty ? 0.0 : Double(reused) / Double(gopCoalesceLogs.count)
        report += "  GOP reuse rate: \(String(format: "%.1f", gopReuseRate * 100))%\n\n"
        
        // Decode summary
        report += "Decodes:\n"
        report += "  Total decodes: \(decodeLogs.count)\n"
        if !decodeLogs.isEmpty {
            let durations = decodeLogs.map { $0.durationMS }
            let avgDuration = durations.reduce(0, +) / Double(durations.count)
            let sortedDurations = durations.sorted()
            let p95Index = Int(Double(sortedDurations.count) * 0.95)
            let p95Duration = sortedDurations[min(p95Index, sortedDurations.count - 1)]
            let p99Index = Int(Double(sortedDurations.count) * 0.99)
            let p99Duration = sortedDurations[min(p99Index, sortedDurations.count - 1)]
            
            report += "  Avg duration: \(String(format: "%.1f", avgDuration))ms\n"
            report += "  P95 duration: \(String(format: "%.1f", p95Duration))ms\n"
            report += "  P99 duration: \(String(format: "%.1f", p99Duration))ms\n"
            
            let lzCount = decodeLogs.filter { $0.reason == "lz" }.count
            let gopCount = decodeLogs.filter { $0.reason == "gop" }.count
            let deadlineCount = decodeLogs.filter { $0.reason == "deadline" }.count
            report += "  By reason: lz=\(lzCount), gop=\(gopCount), deadline=\(deadlineCount)\n"
        }
        report += "\n"
        
        // Render tiling summary
        report += "Render Tiling:\n"
        report += "  Samples: \(tileRenderLogs.count)\n"
        if !tileRenderLogs.isEmpty {
            let tileCounts = tileRenderLogs.map { Double($0.dirtyTileCount) }
            let avgTiles = tileCounts.reduce(0, +) / Double(tileCounts.count)
            let fullFrameCount = tileRenderLogs.filter { $0.fullFrame }.count
            let coverage = tileRenderLogs.map { $0.coverage }
            let avgCoverage = coverage.reduce(0, +) / Double(coverage.count)
            let fullFramePct = Double(fullFrameCount) / Double(tileRenderLogs.count)
            report += "  Avg dirty tiles: \(String(format: "%.1f", avgTiles))\n"
            report += "  Avg coverage: \(String(format: "%.1f", avgCoverage * 100))%\n"
            report += "  Full-frame fallbacks: \(fullFrameCount) (\(String(format: "%.1f", fullFramePct * 100))%)\n"
        }
        report += "\n"

        // Stop metrics
        report += "Stop Metrics:\n"
        report += "  Total stops: \(stopMetricLogs.count)\n"
        if !stopMetricLogs.isEmpty {
            let reverseLogs = stopMetricLogs.filter { $0.direction == .reverse }
            if !reverseLogs.isEmpty {
                let durations = reverseLogs.map { $0.timeToExactFrameMS }
                let avgDuration = durations.reduce(0, +) / Double(durations.count)
                let maxDuration = durations.max() ?? 0
                report += "  Reverse stops: \(reverseLogs.count)\n"
                report += "  Avg time to exact frame: \(String(format: "%.1f", avgDuration))ms\n"
                report += "  Max time to exact frame: \(String(format: "%.1f", maxDuration))ms\n"
                
                let passCount = durations.filter { $0 <= 66.0 }.count
                let passRate = Double(passCount) / Double(durations.count)
                report += "  Pass rate (≤66ms): \(String(format: "%.1f", passRate * 100))%\n"
            }
        }
        
        return report
    }
    
    func exportLogs(to url: URL) throws {
        let report = generateReport()
        try report.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func clearLogs() {
        scrubLogs.removeAll()
        historyCheckLogs.removeAll()
        coalesceLogs.removeAll()
        gopCoalesceLogs.removeAll()
        reverseLZLogs.removeAll()
        decodeLogs.removeAll()
        ringLogs.removeAll()
        stopMetricLogs.removeAll()
        tileRenderLogs.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func trimIfNeeded<T>(_ array: inout [T]) {
        if array.count > maxLogsPerType {
            array.removeFirst(array.count - maxLogsPerType)
        }
    }
}
