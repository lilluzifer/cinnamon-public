import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// A/V Sync Diagnostics System
/// Implements comprehensive logging and analysis for jitter and lip-sync issues
/// Based on DIAGNOSE-PROMPT requirements
@MainActor
final class AVSyncDiagnostics {
    static let shared = AVSyncDiagnostics()
    
    private var isEnabled = false
    private var sessionStartTime: CFTimeInterval = 0
    private var tickCount = 0
    private var audioClockSamples: [(timeline: TimeInterval, audio: TimeInterval, host: CFTimeInterval)] = []
    private var selectionSamples: [SelectionSample] = []
    private var decodeSamples: [DecodeSample] = []
    private var ringSamples: [RingSample] = []
    private var presentSamples: [PresentSample] = []
    private var boundaryEvents: [BoundaryEvent] = []
    
    struct SelectionSample {
        let time: TimeInterval
        let clipID: UUID
        let selectedPTS: TimeInterval
        let nextPTS: TimeInterval?
        let valid: Bool
        let distToNextMs: Double
    }
    
    struct DecodeSample {
        let pts: TimeInterval
        let durationMs: Double
        let reason: String
    }
    
    struct RingSample {
        let clipID: UUID
        let fillPercent: Double
        let inflight: Int
        let cancels: Int
        let hits: Int
        let misses: Int
    }
    
    struct PresentSample {
        let time: TimeInterval
        let latencyMs: Double
        let dropped: Int
    }
    
    struct BoundaryEvent {
        let time: TimeInterval
        let clipID: UUID
        let selectedPTS: TimeInterval
        let nextPTS: TimeInterval
        let distToNextMs: Double
        let wasEarly: Bool
    }
    
    private init() {}
    
    // MARK: - Session Control
    
    func startSession() {
        isEnabled = true
        sessionStartTime = CACurrentMediaTime()
        tickCount = 0
        audioClockSamples.removeAll()
        selectionSamples.removeAll()
        decodeSamples.removeAll()
        ringSamples.removeAll()
        presentSamples.removeAll()
        boundaryEvents.removeAll()
        print("🔬 [AVSyncDiagnostics] Session started")
    }
    
    func stopSession() {
        guard isEnabled else { return }
        isEnabled = false
        
        let duration = CACurrentMediaTime() - sessionStartTime
        print("🔬 [AVSyncDiagnostics] Session stopped after \(String(format: "%.1f", duration))s")
        
        // Generate comprehensive report
        generateReport()
    }
    
    // MARK: - Logging Methods
    
    func logTick(hostTime: CFTimeInterval, dtMs: Double, rate: Double, timeline: TimeInterval, mono: Bool) {
        guard isEnabled else { return }
        tickCount += 1
        
        // Log every 60th tick (once per second at 60Hz)
        if tickCount % 60 == 0 {
            print("[TICK] host=\(String(format: "%.3f", hostTime)) " +
                  "dt_ms=\(String(format: "%.2f", dtMs)) " +
                  "rate=\(rate) " +
                  "timeline=\(String(format: "%.3f", timeline)) " +
                  "mono=\(mono ? "✓" : "✗")")
        }
    }
    
    func logAudioClock(deviceSampleRate: Double, ioBuffer: Int, audioClock: CMTime, timeline: TimeInterval) {
        guard isEnabled else { return }
        
        let audioTime = audioClock.seconds
        let driftMs = (timeline - audioTime) * 1000.0
        let hostTime = CACurrentMediaTime()
        
        audioClockSamples.append((timeline: timeline, audio: audioTime, host: hostTime))
        
        // Log every second
        if audioClockSamples.count % 60 == 0 {
            print("[AUDIO] device_sr=\(Int(deviceSampleRate)) " +
                  "io_buf=\(ioBuffer) " +
                  "audioClock=\(String(format: "%.3f", audioTime))s " +
                  "drift_ms=\(String(format: "%.2f", driftMs))")
        }
    }
    
    func logSelection(time: TimeInterval, clipID: UUID, selectedPTS: TimeInterval, 
                     nextPTS: TimeInterval?, valid: Bool) {
        guard isEnabled else { return }
        
        let distToNextMs = nextPTS.map { ($0 - time) * 1000.0 } ?? Double.infinity
        let sample = SelectionSample(time: time, clipID: clipID, selectedPTS: selectedPTS,
                                    nextPTS: nextPTS, valid: valid, distToNextMs: distToNextMs)
        selectionSamples.append(sample)
        
        // Check for boundary events (within ±10ms of PTS transition)
        if let nextPTS = nextPTS, abs(distToNextMs) <= 10.0 {
            let wasEarly = time < nextPTS && selectedPTS >= nextPTS
            boundaryEvents.append(BoundaryEvent(time: time, clipID: clipID, 
                                               selectedPTS: selectedPTS, nextPTS: nextPTS,
                                               distToNextMs: distToNextMs, wasEarly: wasEarly))
            
            if wasEarly {
                print("[SELECT_BOUNDARY] ⚠️ EARLY SWITCH at t=\(String(format: "%.3f", time))s " +
                      "selectedPTS=\(String(format: "%.3f", selectedPTS)) " +
                      "nextPTS=\(String(format: "%.3f", nextPTS)) " +
                      "dist_ms=\(String(format: "%.2f", distToNextMs))")
            }
        }
        
        // Aggregate logging every second
        if selectionSamples.count % 60 == 0 {
            let recent = selectionSamples.suffix(60)
            let validCount = recent.filter { $0.valid }.count
            let validPercent = Double(validCount) / Double(recent.count) * 100.0
            print("[SELECT] t=\(String(format: "%.3f", time))s " +
                  "valid=\(validPercent)% " +
                  "samples=\(recent.count)")
        }
    }
    
    func logDecode(pts: TimeInterval, durationMs: Double, reason: String) {
        guard isEnabled else { return }
        
        decodeSamples.append(DecodeSample(pts: pts, durationMs: durationMs, reason: reason))
        
        // Log slow decodes immediately
        if durationMs > 20.0 {
            print("[DECODE] ⚠️ SLOW pts=\(String(format: "%.3f", pts))s " +
                  "dur_ms=\(String(format: "%.1f", durationMs)) " +
                  "reason=\(reason)")
        }
    }
    
    func logRing(clipID: UUID, fillPercent: Double, inflight: Int, cancels: Int, hits: Int, misses: Int) {
        guard isEnabled else { return }
        
        ringSamples.append(RingSample(clipID: clipID, fillPercent: fillPercent,
                                     inflight: inflight, cancels: cancels, hits: hits, misses: misses))
        
        // Log every second
        if ringSamples.count % 60 == 0 {
            print("[RING] clip=\(clipID.uuidString.prefix(8)) " +
                  "fill%=\(String(format: "%.0f", fillPercent))% " +
                  "inflight=\(inflight) " +
                  "cancels=\(cancels) " +
                  "hits=\(hits) " +
                  "misses=\(misses)")
        }
        
        // Warn on low fill
        if fillPercent < 40.0 {
            print("[RING] ⚠️ LOW FILL clip=\(clipID.uuidString.prefix(8)) " +
                  "fill%=\(String(format: "%.0f", fillPercent))%")
        }
    }
    
    func logPresent(time: TimeInterval, latencyMs: Double, dropped: Int) {
        guard isEnabled else { return }
        
        presentSamples.append(PresentSample(time: time, latencyMs: latencyMs, dropped: dropped))
        
        // Log every second
        if presentSamples.count % 60 == 0 {
            let recent = presentSamples.suffix(60)
            let avgLatency = recent.map { $0.latencyMs }.reduce(0, +) / Double(recent.count)
            let totalDropped = recent.map { $0.dropped }.reduce(0, +)
            print("[RENDER_1S] dropped=\(totalDropped) " +
                  "presentLatency_avg_ms=\(String(format: "%.2f", avgLatency))")
        }
    }
    
    func logStart(timeToFirstFrameMs: Double, audioStartMs: Double, videoStartMs: Double) {
        guard isEnabled else { return }
        
        print("[START] time_to_first_frame_ms=\(String(format: "%.1f", timeToFirstFrameMs)) " +
              "a_start_ms=\(String(format: "%.1f", audioStartMs)) " +
              "v_start_ms=\(String(format: "%.1f", videoStartMs))")
    }
    
    // MARK: - Analysis & Reporting
    
    private func generateReport() {
        print("\n" + String(repeating: "=", count: 80))
        print("A/V SYNC DIAGNOSTICS REPORT")
        print(String(repeating: "=", count: 80))
        
        analyzeClockDrift()
        analyzeNearestPrevious()
        analyzePresentJitter()
        analyzeRingBuffer()
        analyzeBoundaryStability()
        analyzeDecodePerformance()
        
        print(String(repeating: "=", count: 80) + "\n")
    }
    
    private func analyzeClockDrift() {
        print("\n[GC2] A/V CLOCK DRIFT ANALYSIS")
        print(String(repeating: "-", count: 80))
        
        guard audioClockSamples.count >= 2 else {
            print("❌ INSUFFICIENT DATA: Need at least 2 audio clock samples")
            return
        }
        
        let drifts = audioClockSamples.map { ($0.timeline - $0.audio) * 1000.0 }
        let median = drifts.sorted()[drifts.count / 2]
        let p95Index = Int(Double(drifts.count) * 0.95)
        let p95 = drifts.sorted()[min(p95Index, drifts.count - 1)]
        
        // Calculate trend (drift per minute)
        let firstSample = audioClockSamples.first!
        let lastSample = audioClockSamples.last!
        let duration = lastSample.host - firstSample.host
        let driftChange = (lastSample.timeline - lastSample.audio) - (firstSample.timeline - firstSample.audio)
        let driftPerMinute = duration > 0 ? (driftChange / duration) * 60.0 * 1000.0 : 0
        
        print("Median drift: \(String(format: "%.2f", median))ms")
        print("P95 drift: \(String(format: "%.2f", abs(p95)))ms")
        print("Drift trend: \(String(format: "%.2f", driftPerMinute))ms/min")
        
        // Golden Check GC2
        let medianPass = abs(median) < 5.0
        let p95Pass = abs(p95) < 10.0
        let trendPass = abs(driftPerMinute) < 10.0
        
        if medianPass && p95Pass && trendPass {
            print("✅ PASS: Clock drift within acceptable limits")
        } else {
            print("❌ FAIL: Clock drift exceeds limits")
            if !medianPass { print("  - Median drift \(String(format: "%.2f", abs(median)))ms > 5ms") }
            if !p95Pass { print("  - P95 drift \(String(format: "%.2f", abs(p95)))ms > 10ms") }
            if !trendPass { print("  - Drift trend \(String(format: "%.2f", abs(driftPerMinute)))ms/min > 10ms/min") }
            print("  → H1 (Clock Mismatch): Audio clock vs DisplayLink drift detected")
        }
    }
    
    private func analyzeNearestPrevious() {
        print("\n[GC1] NEAREST-PREVIOUS INVARIANT")
        print(String(repeating: "-", count: 80))
        
        guard !selectionSamples.isEmpty else {
            print("❌ INSUFFICIENT DATA: No selection samples")
            return
        }
        
        let validCount = selectionSamples.filter { $0.valid }.count
        let validPercent = Double(validCount) / Double(selectionSamples.count) * 100.0
        
        print("Valid selections: \(validCount)/\(selectionSamples.count) (\(String(format: "%.1f", validPercent))%)")
        
        if validPercent >= 98.0 {
            print("✅ PASS: NP invariant ≥ 98%")
        } else {
            print("❌ FAIL: NP invariant < 98%")
            print("  → H2 (Timebase/PTS Mapping): Check for off-by-one errors")
        }
    }
    
    private func analyzePresentJitter() {
        print("\n[GC3] PRESENT JITTER ANALYSIS")
        print(String(repeating: "-", count: 80))
        
        guard !presentSamples.isEmpty else {
            print("❌ INSUFFICIENT DATA: No present samples")
            return
        }
        
        let latencies = presentSamples.map { $0.latencyMs }
        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        let p95Index = Int(Double(latencies.count) * 0.95)
        let p95Latency = latencies.sorted()[min(p95Index, latencies.count - 1)]
        let totalDropped = presentSamples.map { $0.dropped }.reduce(0, +)
        
        print("Average latency: \(String(format: "%.2f", avgLatency))ms")
        print("P95 latency: \(String(format: "%.2f", p95Latency))ms")
        print("Total dropped: \(totalDropped)")
        
        let avgPass = avgLatency < 8.0
        let p95Pass = p95Latency < 12.0
        let dropPass = totalDropped == 0
        
        if avgPass && p95Pass && dropPass {
            print("✅ PASS: Present jitter within limits")
        } else {
            print("❌ FAIL: Present jitter exceeds limits")
            if !avgPass { print("  - Avg latency \(String(format: "%.2f", avgLatency))ms > 8ms") }
            if !p95Pass { print("  - P95 latency \(String(format: "%.2f", p95Latency))ms > 12ms") }
            if !dropPass { print("  - Dropped frames: \(totalDropped)") }
            print("  → H3 (Present/Jitter): Renderer latency or v-sync mismatch")
        }
    }
    
    private func analyzeRingBuffer() {
        print("\n[GC4] RING BUFFER ANALYSIS")
        print(String(repeating: "-", count: 80))
        
        guard !ringSamples.isEmpty else {
            print("❌ INSUFFICIENT DATA: No ring buffer samples")
            return
        }
        
        let avgFill = ringSamples.map { $0.fillPercent }.reduce(0, +) / Double(ringSamples.count)
        let minFill = ringSamples.map { $0.fillPercent }.min() ?? 0
        let lowFillCount = ringSamples.filter { $0.fillPercent < 40.0 }.count
        
        print("Average fill: \(String(format: "%.1f", avgFill))%")
        print("Minimum fill: \(String(format: "%.1f", minFill))%")
        print("Low fill events (<40%): \(lowFillCount)")
        
        let avgPass = avgFill >= 60.0
        let minPass = minFill >= 40.0
        
        if avgPass && minPass {
            print("✅ PASS: Ring buffer healthy")
        } else {
            print("❌ FAIL: Ring buffer issues detected")
            if !avgPass { print("  - Avg fill \(String(format: "%.1f", avgFill))% < 60%") }
            if !minPass { print("  - Min fill \(String(format: "%.1f", minFill))% < 40%") }
            print("  → H4 (Ring Dellen): GOP spikes causing buffer depletion")
        }
    }
    
    private func analyzeBoundaryStability() {
        print("\n[GC5] BOUNDARY STABILITY")
        print(String(repeating: "-", count: 80))
        
        guard !boundaryEvents.isEmpty else {
            print("✅ PASS: No boundary events detected (or insufficient data)")
            return
        }
        
        let earlyCount = boundaryEvents.filter { $0.wasEarly }.count
        print("Boundary events: \(boundaryEvents.count)")
        print("Early switches: \(earlyCount)")
        
        if earlyCount == 0 {
            print("✅ PASS: No early frame switches at boundaries")
        } else {
            print("❌ FAIL: Early frame switches detected")
            print("  → H7 (Boundary Fehler): NP threshold incorrect (≥ vs >)")
            
            // Show first few examples
            for event in boundaryEvents.prefix(3) where event.wasEarly {
                print("  Example: t=\(String(format: "%.3f", event.time))s " +
                      "selected=\(String(format: "%.3f", event.selectedPTS)) " +
                      "next=\(String(format: "%.3f", event.nextPTS)) " +
                      "dist=\(String(format: "%.2f", event.distToNextMs))ms")
            }
        }
    }
    
    private func analyzeDecodePerformance() {
        print("\n[DECODE PERFORMANCE]")
        print(String(repeating: "-", count: 80))
        
        guard !decodeSamples.isEmpty else {
            print("❌ INSUFFICIENT DATA: No decode samples")
            return
        }
        
        let durations = decodeSamples.map { $0.durationMs }
        let avgDuration = durations.reduce(0, +) / Double(durations.count)
        let p95Index = Int(Double(durations.count) * 0.95)
        let p95Duration = durations.sorted()[min(p95Index, durations.count - 1)]
        let slowCount = decodeSamples.filter { $0.durationMs > 20.0 }.count
        
        print("Average decode: \(String(format: "%.2f", avgDuration))ms")
        print("P95 decode: \(String(format: "%.2f", p95Duration))ms")
        print("Slow decodes (>20ms): \(slowCount)")
        
        // Analyze GOP spikes
        let gopDecodes = decodeSamples.filter { $0.reason.contains("gop") || $0.reason.contains("IDR") }
        if !gopDecodes.isEmpty {
            let gopDurations = gopDecodes.map { $0.durationMs }
            let avgGOP = gopDurations.reduce(0, +) / Double(gopDurations.count)
            print("GOP/IDR decodes: \(gopDecodes.count), avg=\(String(format: "%.2f", avgGOP))ms")
            
            if avgGOP > 30.0 {
                print("⚠️  GOP spikes detected (avg \(String(format: "%.2f", avgGOP))ms)")
                print("  → Normal for H.264 I-frames, but may cause ring buffer dips")
            }
        }
    }
}
