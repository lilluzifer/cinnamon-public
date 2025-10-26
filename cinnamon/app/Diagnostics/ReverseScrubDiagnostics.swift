import Foundation
import CoreMedia
import CoreVideo
import os

/// Reverse-scrubbing diagnostics for NLE preview
/// Tracks coalescing, GOP reuse, ring buffer, and frame selection during backward scrubbing
@MainActor
final class ReverseScrubDiagnostics {
    static let shared = ReverseScrubDiagnostics()
    
    private let logger = Logger(subsystem: "com.cinnamon.diagnostics", category: "ReverseScrub")
    
    // Enable via UI button OR environment variable
    var isEnabled: Bool = ProcessInfo.processInfo.environment["REVERSE_SCRUB_DIAGNOSTICS"] == "1"
    
    // Metrics tracking
    private var scrubDirection: ScrubDirection = .forward
    private var scrubVelocityFPS: Double = 0
    private var scrubEpoch: UInt64 = 0
    
    // Coalescing metrics
    private var coalescingDecisions: [CoalescingDecision] = []
    private var lastDecodeStartTime: [UUID: CFAbsoluteTime] = [:]
    
    // GOP metrics
    private var gopReuseCount: Int = 0
    private var gopRetargetCount: Int = 0
    private var gopCancelCount: Int = 0
    private var gopTotalRequests: Int = 0
    
    // Ring buffer metrics
    private var ringFillSamples: [RingFillSample] = []
    private var ringInflightSamples: [Int] = []
    
    // Reverse landing zone metrics
    private var landingZoneHits: Int = 0
    private var landingZoneMisses: Int = 0
    
    // Frame selection metrics (NP validation)
    private var npValidCount: Int = 0
    private var npInvalidCount: Int = 0
    private var boundaryViolations: [BoundaryViolation] = []
    
    // Decode timing
    private var decodeTimings: [DecodeTiming] = []
    
    // Present/render metrics
    private var droppedFrames: Int = 0
    private var presentLatencies: [Double] = []
    
    // Admission control
    private var admissionDenials: Int = 0
    private var admissionAllowed: Int = 0
    private var admissionNearGranted: [UUID: Int] = [:]
    private var admissionFarDenied: [UUID: Int] = [:]
    private var admissionPreempted: [UUID: Int] = [:]

    private var lastColorSignature: [UUID: String] = [:]
    
    enum ScrubDirection: String {
        case forward = "→"
        case backward = "←"
        case stopped = "■"
    }
    
    enum ScrubState: String {
        case fast = "FAST"
        case medium = "MEDIUM"
        case slow = "SLOW"
        case stop = "STOP"
    }
    
    struct CoalescingDecision {
        let timestamp: CFAbsoluteTime
        let minIntervalMs: Double
        let startedAgoMs: Double
        let decision: String  // "start" or "skip"
        let equalityFix: Bool  // true if using >= instead of >
    }
    
    struct GOPEvent {
        let gopKey: String
        let reused: Bool
        let retarget: Bool
        let canceled: Bool
    }
    
    struct RingFillSample {
        let timestamp: CFAbsoluteTime
        let fillPercent: Double
        let inflight: Int
        let cancels: Int
    }
    
    struct LandingZoneCheck {
        let tNow: TimeInterval
        let tPred: TimeInterval
        let windowStart: TimeInterval
        let windowEnd: TimeInterval
        let framesWarm: Int
    }
    
    struct DecodeTiming {
        let pts: TimeInterval
        let durationMs: Double
        let reason: String  // "deadline", "lz", "gop"
        let epoch: UInt64
    }
    
    struct BoundaryViolation {
        let time: TimeInterval
        let selectedPTS: TimeInterval
        let nextPTS: TimeInterval?
        let reason: String
    }
    
    private init() {}
    
    // MARK: - A. Scrub State & Direction
    
    func logScrubState(state: ScrubState, direction: ScrubDirection, velocityFPS: Double, epoch: UInt64) {
        guard isEnabled else { return }
        
        scrubDirection = direction
        scrubVelocityFPS = velocityFPS
        scrubEpoch = epoch
        
        print("[SCRUB] state=\(state.rawValue) dir=\(direction.rawValue) velocity_fps=\(String(format: "%.1f", velocityFPS)) epoch=\(epoch)")
    }
    
    // MARK: - B. Coalescing/Admission
    
    func logCoalescing(minIntervalMs: Double, startedAgoMs: Double, decision: String, equalityFix: Bool = true) {
        guard isEnabled else { return }
        
        let record = CoalescingDecision(
            timestamp: CFAbsoluteTimeGetCurrent(),
            minIntervalMs: minIntervalMs,
            startedAgoMs: startedAgoMs,
            decision: decision,
            equalityFix: equalityFix
        )
        coalescingDecisions.append(record)
        
        let eqSymbol = equalityFix ? ">=" : ">"
        print("[COALESCE] minInterval_ms=\(String(format: "%.1f", minIntervalMs)) startedAgo_ms=\(String(format: "%.1f", startedAgoMs)) decision=\(decision) eq_fix={\(eqSymbol)}")
    }
    
    func logAdmission(inflightClip: Int, inflightGlobal: Int, denied: Bool) {
        guard isEnabled else { return }

        if denied {
            admissionDenials += 1
        } else {
            admissionAllowed += 1
        }
        
        print("[ADMISSION] in_flight_clip=\(inflightClip) in_flight_global=\(inflightGlobal) denied=\(denied ? "t" : "f")")
    }

    func logDecoderPath(clipID: UUID, decoder: String, pixelFormat: OSType, pts: TimeInterval) {
        guard isEnabled else { return }

        let formatString = String(format: "0x%08X", pixelFormat)
        print("[PATH] clip=\(clipID.uuidString.prefix(8)) decoder=\(decoder) pixel_format=\(formatString) pts=\(String(format: "%.3f", pts))")
    }

    func logColorMetadata(clipID: UUID, pixelBuffer: CVPixelBuffer, pts: TimeInterval) {
        guard isEnabled else { return }

        func attachmentString(_ key: CFString) -> String {
            if let value = CVBufferGetAttachment(pixelBuffer, key, nil)?.takeUnretainedValue() {
                return "\(value)"
            }
            return "nil"
        }

        let primaries = attachmentString(kCVImageBufferColorPrimariesKey)
        let transfer = attachmentString(kCVImageBufferTransferFunctionKey)
        let matrix = attachmentString(kCVImageBufferYCbCrMatrixKey)

        let fullRangeKey: CFString = "FullRangeVideo" as CFString
        let fullRangeAttachment = CVBufferGetAttachment(pixelBuffer, fullRangeKey, nil)?.takeUnretainedValue()
        let fullRangeString: String
        if let boolValue = fullRangeAttachment as? Bool {
            fullRangeString = boolValue ? "t" : "f"
        } else if let number = fullRangeAttachment as? NSNumber {
            fullRangeString = number.boolValue ? "t" : "f"
        } else if let cfBool = fullRangeAttachment, CFGetTypeID(cfBool) == CFBooleanGetTypeID() {
            fullRangeString = CFBooleanGetValue(unsafeBitCast(cfBool, to: CFBoolean.self)) ? "t" : "f"
        } else {
            fullRangeString = "nil"
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let formatString = String(format: "0x%08X", pixelFormat)
        let signature = "\(primaries)|\(transfer)|\(matrix)|\(fullRangeString)|\(formatString)"

        if lastColorSignature[clipID] != signature {
            lastColorSignature[clipID] = signature
            print("[COLOR] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) fullRange=\(fullRangeString) pixel_format=\(formatString)")
        }
    }

    func logTargetSelection(tPred: TimeInterval,
                            selected: [(pts: TimeInterval, reason: String)],
                            droppedFar: Int,
                            windowFill: Double) {
        guard isEnabled else { return }

        let selectedDesc = selected
            .map { "\(String(format: "%.3f", $0.pts))@\($0.reason)" }
            .joined(separator: ",")
        let fillPercent = max(min(windowFill * 100.0, 100.0), 0.0)
        print("[TARGETS] t_pred=\(String(format: "%.3f", tPred)) selected=[\(selectedDesc)] dropped_far=\(droppedFar) window_fill%=\(String(format: "%.1f", fillPercent))")
    }

    func logAdmissionDetail(clipID: UUID,
                            purpose: String,
                            admitted: Bool,
                            clipInflight: Int,
                            globalInflight: Int,
                            nearReverseRepair: Bool) {
        guard isEnabled else { return }
        print("[ADMISSION] clip=\(clipID.uuidString.prefix(8)) purpose=\(purpose) admitted=\(admitted ? "t" : "f") clip=\(clipInflight) global=\(globalInflight) near_reverse=\(nearReverseRepair ? "t" : "f")")
    }

    private func emitAdmissionStats(clipID: UUID,
                                    nearGranted: Int,
                                    farDenied: Int,
                                    inflight: Int,
                                    global: Int,
                                    preempted: Int) {
        guard isEnabled else { return }
        print("[ADMISSION_STATS] clip=\(clipID.uuidString.prefix(8)) nearGranted=\(nearGranted) farDenied=\(farDenied) in_flight=\(inflight) global=\(global) preempted=\(preempted)")
    }

    func updateAdmissionStats(clipID: UUID,
                              nearGrantedDelta: Int,
                              farDeniedDelta: Int,
                              preemptedDelta: Int,
                              inflight: Int,
                              global: Int) {
        guard isEnabled else { return }
        admissionNearGranted[clipID, default: 0] += nearGrantedDelta
        admissionFarDenied[clipID, default: 0] += farDeniedDelta
        admissionPreempted[clipID, default: 0] += preemptedDelta

        emitAdmissionStats(clipID: clipID,
                           nearGranted: admissionNearGranted[clipID] ?? 0,
                           farDenied: admissionFarDenied[clipID] ?? 0,
                           inflight: inflight,
                           global: global,
                           preempted: admissionPreempted[clipID] ?? 0)
    }

    func logRepair(errorFrames: Double, offsetSeconds: Double, retarget: Bool) {
        guard isEnabled else { return }
        print("[REPAIR] err_frames=\(String(format: "%.2f", errorFrames)) offset_ms=\(String(format: "%.1f", offsetSeconds * 1000)) retarget=\(retarget ? "t" : "f")")
    }

    func logLateFrame(clipID: UUID, leadMS: Double, usedForDisplay: Bool) {
        guard isEnabled else { return }
        print("[LATE] clip=\(clipID.uuidString.prefix(8)) lead_ms=\(String(format: "%.1f", leadMS)) used_for_display=\(usedForDisplay ? "t" : "f")")
    }

    func logDisplayDecision(clipID: UUID,
                            swapped: Bool,
                            ageMS: Double,
                            holdReason: String) {
        guard isEnabled else { return }
        print("[DISPLAY] clip=\(clipID.uuidString.prefix(8)) swap=\(swapped ? "t" : "f") age_ms=\(String(format: "%.1f", ageMS)) reason=\(holdReason)")
    }

    func logDisplayFallback(clipID: UUID,
                            pts: TimeInterval,
                            ageMS: Double,
                            reason: String) {
        guard isEnabled else { return }
        print("[DISPLAY_FALLBACK] clip=\(clipID.uuidString.prefix(8)) pts=\(String(format: "%.3f", pts)) age_ms=\(String(format: "%.1f", ageMS)) reason=\(reason)")
    }

    func logDisplaySLA(clipID: UUID,
                       deltaMS: Double,
                       immediate: Bool) {
        guard isEnabled else { return }
        print("[DISPLAY_SLA] clip=\(clipID.uuidString.prefix(8)) delta_ms=\(String(format: "%.1f", deltaMS)) immediate=\(immediate ? "t" : "f")")
    }

    func logReaderWindow(clipID: UUID,
                         randomAccessPTS: TimeInterval?,
                         randomAccessKind: String?,
                         window: ClosedRange<TimeInterval>,
                         decoded: Bool,
                         attempts: Int,
                         droppedLeading: Int,
                         shownPTS: TimeInterval?,
                         errorCode: Int?) {
        guard isEnabled else { return }
        let raString = randomAccessPTS.map { String(format: "%.3f", $0) } ?? "nil"
        let kindString = randomAccessKind ?? "nil"
        let shownString = shownPTS.map { String(format: "%.3f", $0) } ?? "nil"
        let errorString = errorCode.map(String.init) ?? "nil"
        print("[SCRUB_READER] clip=\(clipID.uuidString.prefix(8)) decoded=\(decoded ? "t" : "f") attempts=\(attempts) ra=\(raString) kind=\(kindString) droppedLeading=\(droppedLeading) window=[\(String(format: "%.3f", window.lowerBound))…\(String(format: "%.3f", window.upperBound))] shown=\(shownString) err=\(errorString)")
    }

    func logRandomAccessFallback(clipID: UUID,
                                 fromPTS: TimeInterval,
                                 toPTS: TimeInterval) {
        guard isEnabled else { return }
        print("[GOP_FALLBACK] clip=\(clipID.uuidString.prefix(8)) from=\(String(format: "%.3f", fromPTS)) to=\(String(format: "%.3f", toPTS))")
    }

    func logWatchdog(clipID: UUID, reason: String) {
        guard isEnabled else { return }
        print("[WATCHDOG] clip=\(clipID.uuidString.prefix(8)) reason=\(reason)")
    }

    func logRandomAccessSelection(clipID: UUID,
                                  targetPTS: TimeInterval,
                                  result: GOPAnalyzer.RandomAccessResult,
                                  prerollFrames: Int) {
        guard isEnabled else { return }

        func flagString(_ value: Bool?) -> String {
            switch value {
            case .some(true): return "t"
            case .some(false): return "f"
            case .none: return "nil"
            }
        }

        let kindString = result.kind.rawValue.uppercased()
        let flags = result.flags
        print("[GOP] clip=\(clipID.uuidString.prefix(8)) target=\(String(format: "%.3f", targetPTS)) pickedRA kind=\(kindString) fallback=\(result.isFallback ? "t" : "f") requiresPreroll=\(result.requiresPreroll ? "t" : "f") prerollF=\(prerollFrames) notSync=\(flagString(flags.notSync)) depends=\(flagString(flags.dependsOnOthers)) randomAccess=\(flagString(flags.randomAccess)) noTemporalRef=\(flagString(flags.noTemporalReference)) partialSync=\(flagString(flags.partialSync)) isDepended=\(flagString(flags.isDependedOnByOthers))")
    }

    func logMetalTexture(label: String,
                         status: CVReturn,
                         pixelFormat: OSType,
                         planesOK: Bool,
                         hasIOSurface: Bool) {
        guard isEnabled else { return }
        let formatString = String(format: "0x%08X", pixelFormat)
        let statusString = status == kCVReturnSuccess ? "0" : String(status)
        print("[METAL_TEX] label=\(label) status=\(statusString) pixfmt=\(formatString) planes_ok=\(planesOK ? "t" : "f") iosurface=\(hasIOSurface ? "t" : "f")")
    }

    func logHistoryTrim(clipID: UUID,
                        direction: String,
                        windowSeconds: TimeInterval,
                        removedCount: Int) {
        guard isEnabled else { return }
        print("[HISTORY] clip=\(clipID.uuidString.prefix(8)) trim=\(direction) window_ms=\(String(format: "%.1f", windowSeconds * 1000)) removed=\(removedCount)")
    }

    func logStoreDecision(clipID: UUID,
                          reason: String,
                          targetPTS: TimeInterval,
                          actualPTS: TimeInterval,
                          storeInPrimary: Bool,
                          deltaMS: Double) {
        guard isEnabled else { return }
        print("[STORE] clip=\(clipID.uuidString.prefix(8)) reason=\(reason) target=\(String(format: "%.3f", targetPTS)) actual=\(String(format: "%.3f", actualPTS)) delta_ms=\(String(format: "%.1f", deltaMS)) primary=\(storeInPrimary ? "t" : "f")")
    }

    func logPrepareSource(clipID: UUID,
                          targetMs: Int64,
                          reason: String,
                          desiredSource: String,
                          switching: Bool,
                          ready: Bool,
                          note: String? = nil) {
        guard isEnabled else { return }
        let noteText = note ?? "-"
        print("[PREPARE] clip=\(clipID.uuidString.prefix(8)) target_ms=\(targetMs) reason=\(reason) desired=\(desiredSource) switching=\(switching ? "t" : "f") ready=\(ready ? "t" : "f") note=\(noteText)")
    }

    func logWarmSequence(clipID: UUID,
                         targetPTS: TimeInterval,
                         actualPTS: TimeInterval?,
                         warmTimes: [TimeInterval],
                         label: String) {
        guard isEnabled else { return }
        let targetString = String(format: "%.3f", targetPTS)
        let actualString = actualPTS.map { String(format: "%.3f", $0) } ?? "nil"
        let timesString: String
        if warmTimes.isEmpty {
            timesString = "[]"
        } else {
            let formatted = warmTimes.map { String(format: "%.3f", $0) }
            timesString = "[" + formatted.joined(separator: ",") + "]"
        }
        print("[WARM_SEQ] clip=\(clipID.uuidString.prefix(8)) label=\(label) target=\(targetString) actual=\(actualString) warm=\(timesString)")
    }

    func logDecoderError(clipID: UUID,
                         code: Int,
                         stage: String,
                         context: String) {
        guard isEnabled else { return }
        print("[DECODER_ERR] clip=\(clipID.uuidString.prefix(8)) code=\(code) stage=\(stage) ctx=\(context)")
    }

    func logRAMetadata(clipID: UUID,
                       anchor: TimeInterval,
                       kind: String,
                       leadFrames: Int,
                       window: ClosedRange<TimeInterval>,
                       coversTarget: Bool) {
        guard isEnabled else { return }
        let anchorString = String(format: "%.3f", anchor)
        let startString = String(format: "%.3f", window.lowerBound)
        let endString = String(format: "%.3f", window.upperBound)
        print("[RA_META] clip=\(clipID.uuidString.prefix(8)) anchor=\(anchorString) kind=\(kind) bRefLead=\(leadFrames) window=[\(startString)…\(endString)] coversTarget=\(coversTarget ? "true" : "false")")
    }

    func logReaderRange(clipID: UUID,
                        window: ClosedRange<TimeInterval>,
                        target: TimeInterval,
                        covers: Bool) {
        guard isEnabled else { return }
        let startString = String(format: "%.3f", window.lowerBound)
        let endString = String(format: "%.3f", window.upperBound)
        let targetString = String(format: "%.3f", target)
        print("[READER_RANGE] clip=\(clipID.uuidString.prefix(8)) start=\(startString) end=\(endString) target=\(targetString) covers=\(covers ? "true" : "false")")
    }

    func logVTOrder(samplesForward: Bool,
                    firstHasFormatDesc: Bool,
                    monotonicDTS: Bool) {
        guard isEnabled else { return }
        print("[VT_ORDER] samplesForward=\(samplesForward ? "true" : "false") firstHasFormatDesc=\(firstHasFormatDesc ? "true" : "false") monotonicDTS=\(monotonicDTS ? "true" : "false")")
    }

    func logImmediateAdmission(clipID: UUID,
                               reason: String,
                               warmBehind: Int,
                               requiredBehind: Int,
                               velocityFPS: Double) {
        guard isEnabled else { return }
        print("[IMMEDIATE] clip=\(clipID.uuidString.prefix(8)) reason=\(reason) warm=\(warmBehind)/\(requiredBehind) velocity=\(String(format: "%.2f", velocityFPS))")
    }
    
    // MARK: - C. GOP Reuse/Retarget
    
    func logGOPCoalescing(gopKey: String, reused: Bool, retarget: Bool, canceled: Bool) {
        guard isEnabled else { return }
        
        gopTotalRequests += 1
        if reused { gopReuseCount += 1 }
        if retarget { gopRetargetCount += 1 }
        if canceled { gopCancelCount += 1 }
        
        print("[COALESCE_GOP] gopKey=\(gopKey) reused=\(reused ? "t" : "f") retarget=\(retarget ? "t" : "f") canceled=\(canceled ? "t" : "f")")
    }
    
    // MARK: - D. Reverse Landing Zone & Predictor
    
    func logReverseLandingZone(tNow: TimeInterval,
                               tPred: TimeInterval,
                               behindRange: ClosedRange<TimeInterval>,
                               aheadRange: ClosedRange<TimeInterval>,
                               warmBehind: Int,
                               warmAhead: Int) {
        guard isEnabled else { return }
        
        if warmBehind >= 1 {
            landingZoneHits += 1
        } else {
            landingZoneMisses += 1
        }
        
        let behindStart = String(format: "%.3f", behindRange.lowerBound)
        let behindEnd = String(format: "%.3f", behindRange.upperBound)
        let aheadEnd = String(format: "%.3f", aheadRange.upperBound)
        print("[REV_LZ] t_now=\(String(format: "%.3f", tNow)) t_pred=\(String(format: "%.3f", tPred)) behind=[\(behindStart)…\(behindEnd)] ahead_end=\(aheadEnd) warmBehind=\(warmBehind) warmAhead=\(warmAhead)")
    }
    
    // MARK: - E. Ring & Decode
    
    func logRingStatus(layer: String, fillPercent: Double, inflight: Int, cancels: Int, hits: Int, misses: Int) {
        guard isEnabled else { return }
        
        let sample = RingFillSample(
            timestamp: CFAbsoluteTimeGetCurrent(),
            fillPercent: fillPercent,
            inflight: inflight,
            cancels: cancels
        )
        ringFillSamples.append(sample)
        ringInflightSamples.append(inflight)
        
        print("[RING \(layer)] fill%=\(String(format: "%.1f", fillPercent)) inflight=\(inflight) cancels=\(cancels) hits=\(hits) misses=\(misses)")
    }
    
    func logDecode(pts: TimeInterval, durationMs: Double, reason: String, epoch: UInt64) {
        guard isEnabled else { return }
        
        let timing = DecodeTiming(pts: pts, durationMs: durationMs, reason: reason, epoch: epoch)
        decodeTimings.append(timing)
        
        print("[DECODE] pts=\(String(format: "%.3f", pts)) dur_ms=\(String(format: "%.1f", durationMs)) reason=\(reason) epoch=\(epoch)")
    }
    
    // MARK: - F. Selection (NP validation at boundaries)
    
    func logSelection(time: TimeInterval, clipID: UUID, selectedPTS: TimeInterval, nextPTS: TimeInterval?, valid: Bool) {
        guard isEnabled else { return }
        
        // Only log at PTS boundaries (±10ms)
        let distToPrev = abs(time - selectedPTS)
        let distToNext = nextPTS.map { abs(time - $0) } ?? Double.infinity
        let nearBoundary = distToPrev <= 0.010 || distToNext <= 0.010
        
        guard nearBoundary else { return }
        
        if valid {
            npValidCount += 1
        } else {
            npInvalidCount += 1
            let violation = BoundaryViolation(
                time: time,
                selectedPTS: selectedPTS,
                nextPTS: nextPTS,
                reason: "NP invariant violated"
            )
            boundaryViolations.append(violation)
        }
        
        let nextStr = nextPTS.map { String(format: "%.3f", $0) } ?? "nil"
        let distStr = nextPTS.map { String(format: "%.1f", abs(time - $0) * 1000) } ?? "∞"
        print("[SELECT \(clipID.uuidString.prefix(8))] t=\(String(format: "%.3f", time)) selectedPTS=\(String(format: "%.3f", selectedPTS)) nextPTS=\(nextStr) valid=\(valid ? "t" : "f") dist_to_next_ms=\(distStr)")
    }
    
    // MARK: - G. Present/Jitter (1×/s)
    
    private var lastPresentLog: CFAbsoluteTime = 0
    
    func logPresent(latencyMs: Double, dropped: Bool = false) {
        guard isEnabled else { return }
        
        presentLatencies.append(latencyMs)
        if dropped {
            droppedFrames += 1
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPresentLog >= 1.0 {
            let avgLatency = presentLatencies.isEmpty ? 0 : presentLatencies.reduce(0, +) / Double(presentLatencies.count)
            let p95Latency = percentile(presentLatencies, 0.95)
            
            print("[RENDER_1S] dropped=\(droppedFrames) presentLatency_avg_ms=\(String(format: "%.2f", avgLatency)) p95_ms=\(String(format: "%.2f", p95Latency))")
            
            presentLatencies.removeAll()
            droppedFrames = 0
            lastPresentLog = now
        }
    }
    
    // MARK: - Analysis & Reporting
    
    func generateReport() -> String {
        var report = """
        ═══════════════════════════════════════════════════════════════
        REVERSE SCRUBBING DIAGNOSTIC REPORT
        ═══════════════════════════════════════════════════════════════
        
        """
        
        // H1: Gate/Equality Check
        report += "\n[H1] COALESCING GATE (Equality Bug)\n"
        report += "────────────────────────────────────\n"
        let skippedAtEquality = coalescingDecisions.filter { decision in
            decision.decision == "skip" && abs(decision.startedAgoMs - decision.minIntervalMs) < 0.5
        }
        report += "Skipped at exact interval: \(skippedAtEquality.count)/\(coalescingDecisions.count)\n"
        if !skippedAtEquality.isEmpty {
            report += "⚠️  ISSUE: Decodes skipped at exact 25/33ms boundary (use >= not >)\n"
            report += "Evidence: \(skippedAtEquality.prefix(2).map { "Δ=\(String(format: "%.1f", $0.startedAgoMs))ms" }.joined(separator: ", "))\n"
        } else {
            report += "✅ OK: No equality-boundary skips detected\n"
        }
        
        // H2: GOP Thrash
        report += "\n[H2] GOP REUSE/THRASH\n"
        report += "────────────────────────────────────\n"
        let reusePercent = gopTotalRequests > 0 ? Double(gopReuseCount) * 100.0 / Double(gopTotalRequests) : 0
        report += "GOP reuse: \(gopReuseCount)/\(gopTotalRequests) (\(String(format: "%.1f", reusePercent))%)\n"
        report += "GOP retarget: \(gopRetargetCount)\n"
        report += "GOP cancel: \(gopCancelCount)\n"
        if reusePercent < 60 {
            report += "⚠️  ISSUE: Low GOP reuse (<60%) suggests thrashing\n"
            report += "Evidence: cancel_rate=\(gopCancelCount)/\(gopTotalRequests)\n"
        } else {
            report += "✅ OK: GOP reuse ≥60%\n"
        }
        
        // H3: Reverse Landing Zone
        report += "\n[H3] REVERSE LANDING ZONE\n"
        report += "────────────────────────────────────\n"
        let lzHitRate = (landingZoneHits + landingZoneMisses) > 0
            ? Double(landingZoneHits) * 100.0 / Double(landingZoneHits + landingZoneMisses)
            : 0
        report += "LZ hits: \(landingZoneHits), misses: \(landingZoneMisses) (\(String(format: "%.1f", lzHitRate))%)\n"
        if lzHitRate < 80 {
            report += "⚠️  ISSUE: Low LZ hit rate suggests missing reverse buffer\n"
        } else {
            report += "✅ OK: LZ hit rate ≥80%\n"
        }
        
        // H4: Ring Dellen (IDR spikes)
        report += "\n[H4] RING BUFFER STABILITY\n"
        report += "────────────────────────────────────\n"
        if !ringFillSamples.isEmpty {
            let avgFill = ringFillSamples.map(\.fillPercent).reduce(0, +) / Double(ringFillSamples.count)
            let minFill = ringFillSamples.map(\.fillPercent).min() ?? 0
            report += "Avg fill: \(String(format: "%.1f", avgFill))%, min: \(String(format: "%.1f", minFill))%\n"
            
            let dellen = ringFillSamples.filter { $0.fillPercent < 30 }
            if !dellen.isEmpty {
                report += "⚠️  ISSUE: \(dellen.count) ring dellen <30% detected\n"
                report += "Evidence: Likely IDR decode spikes causing buffer drain\n"
            } else if avgFill < 40 {
                report += "⚠️  ISSUE: Average fill <40% suggests starvation\n"
            } else {
                report += "✅ OK: Ring buffer stable (≥40%)\n"
            }
        } else {
            report += "⚠️  No ring samples collected\n"
        }
        
        // H5: Boundary Violations (NP)
        report += "\n[H5] NP BOUNDARY VALIDATION\n"
        report += "────────────────────────────────────\n"
        let npTotal = npValidCount + npInvalidCount
        let npQuote = npTotal > 0 ? Double(npValidCount) * 100.0 / Double(npTotal) : 0
        report += "NP valid: \(npValidCount)/\(npTotal) (\(String(format: "%.1f", npQuote))%)\n"
        if npQuote < 98 {
            report += "⚠️  ISSUE: NP quote <98% - boundary comparison errors\n"
            if !boundaryViolations.isEmpty {
                report += "Evidence: \(boundaryViolations.prefix(2).map { "t=\(String(format: "%.3f", $0.time)) sel=\(String(format: "%.3f", $0.selectedPTS))" }.joined(separator: ", "))\n"
            }
        } else {
            report += "✅ OK: NP invariant holds ≥98%\n"
        }
        
        // H6: Predictor
        report += "\n[H6] PREDICTOR (not yet implemented)\n"
        report += "────────────────────────────────────\n"
        report += "⚠️  Predictor logic not yet instrumented\n"
        report += "TODO: Check t_pred = t_now + clamp(velocity * 0.12, -0.5, 0)\n"
        
        // H7: Admission Control
        report += "\n[H7] ADMISSION CONTROL\n"
        report += "────────────────────────────────────\n"
        let admissionTotal = admissionAllowed + admissionDenials
        let denialRate = admissionTotal > 0 ? Double(admissionDenials) * 100.0 / Double(admissionTotal) : 0
        report += "Denied: \(admissionDenials)/\(admissionTotal) (\(String(format: "%.1f", denialRate))%)\n"
        if denialRate > 20 {
            report += "⚠️  ISSUE: High denial rate (>20%) suggests over-restriction\n"
        } else if denialRate < 5 && admissionTotal > 100 {
            report += "⚠️  ISSUE: Very low denial rate (<5%) - may allow thrashing\n"
        } else {
            report += "✅ OK: Admission control balanced\n"
        }
        
        // Decode timing analysis
        report += "\n[DECODE TIMING]\n"
        report += "────────────────────────────────────\n"
        if !decodeTimings.isEmpty {
            let avgDecode = decodeTimings.map(\.durationMs).reduce(0, +) / Double(decodeTimings.count)
            let p95Decode = percentile(decodeTimings.map(\.durationMs), 0.95)
            let p99Decode = percentile(decodeTimings.map(\.durationMs), 0.99)
            report += "Avg: \(String(format: "%.1f", avgDecode))ms, p95: \(String(format: "%.1f", p95Decode))ms, p99: \(String(format: "%.1f", p99Decode))ms\n"
            
            let slowDecodes = decodeTimings.filter { $0.durationMs > 25 }
            if !slowDecodes.isEmpty {
                report += "Slow decodes (>25ms): \(slowDecodes.count)/\(decodeTimings.count)\n"
            }
        } else {
            report += "No decode timings collected\n"
        }
        
        // Present latency
        report += "\n[PRESENT LATENCY]\n"
        report += "────────────────────────────────────\n"
        if !presentLatencies.isEmpty {
            let avgPresent = presentLatencies.reduce(0, +) / Double(presentLatencies.count)
            let p95Present = percentile(presentLatencies, 0.95)
            report += "Avg: \(String(format: "%.2f", avgPresent))ms, p95: \(String(format: "%.2f", p95Present))ms\n"
            report += "Dropped frames: \(droppedFrames)\n"
        }
        
        report += "\n═══════════════════════════════════════════════════════════════\n"
        
        return report
    }
    
    func reset() {
        coalescingDecisions.removeAll()
        gopReuseCount = 0
        gopRetargetCount = 0
        gopCancelCount = 0
        gopTotalRequests = 0
        ringFillSamples.removeAll()
        ringInflightSamples.removeAll()
        landingZoneHits = 0
        landingZoneMisses = 0
        npValidCount = 0
        npInvalidCount = 0
        boundaryViolations.removeAll()
        decodeTimings.removeAll()
        droppedFrames = 0
        presentLatencies.removeAll()
        admissionDenials = 0
        admissionAllowed = 0
    }
    
    // MARK: - Utilities
    
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count) * p)
        return sorted[min(index, sorted.count - 1)]
    }
}
