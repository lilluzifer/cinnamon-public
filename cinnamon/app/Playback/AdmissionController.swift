import Foundation

/// Phase 2.5: Admission control & direction-sensitive gates.
/// Controls decode admission to prevent thrashing.
actor AdmissionController {
    
    // MARK: - Types
    
    struct AdmissionResult {
        let admitted: Bool
        let reason: String
        let clipInflight: Int
        let globalInflight: Int
    }
    
    // MARK: - Properties
    
    private let config: ScrubFeatureFlags.Config
    private var perClipInflight: [UUID: Int] = [:]
    private var globalInflight: Int = 0
    private var lastDecodeTime: [UUID: CFAbsoluteTime] = [:]
    private var burstStartTime: [UUID: CFAbsoluteTime] = [:]
    private var rateGateDenials: [UUID: Int] = [:]
    private var lastRateGateOverride: [UUID: CFAbsoluteTime] = [:]
    private var reverseInflightPerClip: [UUID: Int] = [:]
    private var reverseStartTime: [UUID: CFAbsoluteTime] = [:]
    private enum ReverseSlotOwner: String {
        case reverse
        case repair
        case deadline
    }
    private struct ReverseSlot {
        private(set) var counts: [ReverseSlotOwner: Int] = [:]

        mutating func tryAcquire(owner newOwner: ReverseSlotOwner,
                                 capacity: Int,
                                 allowSteal: Bool = false) -> Bool {
            let current = counts[newOwner] ?? 0
            if current < capacity {
                counts[newOwner] = current + 1
                return true
            }
            let total = counts.values.reduce(0, +)
            if allowSteal && total >= capacity {
                if let victim = counts.first(where: { $0.value > 0 })?.key {
                    release(owner: victim)
                } else {
                    release(owner: nil)
                }
                let updated = (counts[newOwner] ?? 0) + 1
                counts[newOwner] = updated
                return true
            }
            return false
        }

        mutating func release(owner expectedOwner: ReverseSlotOwner? = nil) {
            if let expectedOwner {
                guard var current = counts[expectedOwner] else { return }
                current -= 1
                if current > 0 {
                    counts[expectedOwner] = current
                } else {
                    counts.removeValue(forKey: expectedOwner)
                }
                return
            }

            if let key = counts.keys.first {
                release(owner: key)
            }
        }

        var isHeld: Bool { !counts.isEmpty }
    }
    private var reverseSlots: [UUID: ReverseSlot] = [:]
    private struct AdmissionStats {
        var nearGranted: Int = 0
        var farDenied: Int = 0
        var preempted: Int = 0
    }
    private var stats: [UUID: AdmissionStats] = [:]

    private func reverseSlotCandidate(direction: ScrubCoordinator.ScrubDirection,
                                       purpose: String) -> ReverseSlotOwner? {
        if purpose.lowercased().contains("deadline") {
            return .deadline
        }
        if purpose.hasPrefix("repair") {
            return .repair
        }
        if direction == .reverse {
            return .reverse
        }
        return nil
    }

    // MARK: - Initialization
    
    init(config: ScrubFeatureFlags.Config) {
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Checks if decode should be admitted for given clip and direction.
    func checkAdmission(clipID: UUID,
                        direction: ScrubCoordinator.ScrubDirection,
                        velocityFPS: Double,
                        isStop: Bool,
                        purpose: String,
                        needsImmediate: Bool,
                        warmBehind: Int,
                        warmRequired: Int) async -> AdmissionResult {
        let now = CFAbsoluteTimeGetCurrent()
        let clipInflight = perClipInflight[clipID] ?? 0
        let admissionKind = admissionKind(for: purpose)
        let isCriticalPurpose = purpose == "pred" || purpose == "lz" || purpose == "now"
        let warmBehindCount = warmBehind
        let warmShort = warmBehindCount < warmRequired

        let isReverse = direction == .reverse
        let isRepair = purpose.hasPrefix("repair")
        let isNearReverseRepair = isReverse && isRepair
        let urgentAdmission = needsImmediate || warmShort
        let isNearReverse = isReverse && urgentAdmission
        let reverseSlot = StableScrubMode.enabled ? reverseSlotCandidate(direction: direction, purpose: purpose) : nil
        var globalOverrideUsed = false

        let deadlineEnabled = await MainActor.run { ScrubFeatureFlags.shared.deadlineDecode }
        let deadlineBypass = isStop && deadlineEnabled
        
        if !deadlineBypass {
            // Check global limit
            let slack = config.reverseGlobalSlack
            let extraGlobalSlot: Int
            if isNearReverseRepair || isNearReverse {
                extraGlobalSlot = max(1, slack)
            } else if isReverse {
                extraGlobalSlot = max(0, slack - 1)
            } else {
                extraGlobalSlot = 0
            }
            let globalAllowance = config.maxConcurrentDecodes + extraGlobalSlot
            if globalInflight >= globalAllowance {
                if isReverse && (needsImmediate || warmShort) {
                    globalOverrideUsed = true
                    let clipTag = clipID.uuidString.prefix(8)
                    print("[ADMISSION_OVERRIDE] clip=\(clipTag) type=global warmShort=\(warmShort) inflight=\(globalInflight) allowance=\(globalAllowance)")
                } else {
                    await logAdmission(clipID: clipID,
                                       admitted: false,
                                       reason: "global_limit",
                                       clipInflight: clipInflight,
                                       globalInflight: globalInflight,
                                       kind: admissionKind,
                                       criticalUsed: reverseSlot != nil)
                    let currentGlobal = globalInflight
                    await MainActor.run {
                        ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                                          purpose: purpose,
                                                                          admitted: false,
                                                                          clipInflight: clipInflight,
                                                                          globalInflight: currentGlobal,
                                                                          nearReverseRepair: isNearReverseRepair)
                    }
                    await recordAdmissionStats(clipID: clipID,
                                               nearGrantedDelta: 0,
                                               farDeniedDelta: urgentAdmission ? 0 : 1,
                                               preemptedDelta: urgentAdmission ? 1 : 0,
                                               inflight: clipInflight,
                                               global: currentGlobal)
                    rateGateDenials[clipID] = 0
                    return AdmissionResult(
                        admitted: false,
                        reason: "global_limit",
                        clipInflight: clipInflight,
                        globalInflight: globalInflight
                    )
                }
            }

            // Check per-clip limit (with burst allowance)
            let baseMaxPerClip = isInBurst(clipID: clipID, now: now) ? 
                config.maxInFlightBurstPerClip : config.maxInFlightPerClip

            var maxPerClip = baseMaxPerClip
            if isReverse && warmBehind == 0 {
                let slack = max(2, config.reverseClipSlack)
                maxPerClip += slack
                print("[ADMISSION_WARM_SLACK] clip=\(clipID.uuidString.prefix(8)) warmBehind=0 adding=\(slack) max=\(maxPerClip)")
            }
            if !isReverse && (isNearReverseRepair || isNearReverse) {
                maxPerClip += 1
            }

            if isReverse,
               clipInflight >= maxPerClip,
               let start = reverseStartTime[clipID],
               config.reverseRescueThreshold > 0,
               now - start >= config.reverseRescueThreshold {
                let slack = max(1, config.reverseClipSlack)
                maxPerClip += slack
                reverseStartTime[clipID] = now
                let thresholdMs = Int(config.reverseRescueThreshold * 1000)
                print("[ADMISSION_RESCUE] clip=\(clipID.uuidString.prefix(8)) slack=\(slack) threshold=\(thresholdMs)ms")
            }

            let effectivePerClip = maxPerClip
            if clipInflight >= effectivePerClip {
                await logAdmission(clipID: clipID,
                                   admitted: false,
                                   reason: "clip_limit",
                                   clipInflight: clipInflight,
                                   globalInflight: globalInflight,
                                   kind: admissionKind,
                                   criticalUsed: reverseSlot != nil)
                let currentGlobal = globalInflight
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                                      purpose: purpose,
                                                                      admitted: false,
                                                                      clipInflight: clipInflight,
                                                                      globalInflight: currentGlobal,
                                                                      nearReverseRepair: isNearReverseRepair)
                }
                await recordAdmissionStats(clipID: clipID,
                                           nearGrantedDelta: 0,
                                           farDeniedDelta: urgentAdmission ? 0 : 1,
                                           preemptedDelta: urgentAdmission ? 1 : 0,
                                           inflight: clipInflight,
                                           global: currentGlobal)
                rateGateDenials[clipID] = 0
                return AdmissionResult(
                    admitted: false,
                    reason: "clip_limit",
                    clipInflight: clipInflight,
                    globalInflight: globalInflight
                )
            }

            if clipInflight == 0 {
                rateGateDenials[clipID] = 0
            }

            if isReverse && !urgentAdmission && clipInflight >= config.maxInFlightPerClip {
                await logAdmission(clipID: clipID,
                                   admitted: false,
                                   reason: "clip_limit_far",
                                   clipInflight: clipInflight,
                                   globalInflight: globalInflight,
                                   kind: admissionKind,
                                   criticalUsed: reverseSlot != nil)
                let currentGlobal = globalInflight
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                                      purpose: purpose,
                                                                      admitted: false,
                                                                      clipInflight: clipInflight,
                                                                      globalInflight: currentGlobal,
                                                                      nearReverseRepair: isNearReverseRepair)
                }
                await recordAdmissionStats(clipID: clipID,
                                           nearGrantedDelta: 0,
                                           farDeniedDelta: 1,
                                           preemptedDelta: 0,
                                           inflight: clipInflight,
                                           global: currentGlobal)
                return AdmissionResult(admitted: false,
                                       reason: "clip_limit_far",
                                       clipInflight: clipInflight,
                                       globalInflight: globalInflight)
            }

            let telemetryEnabled = await MainActor.run { ScrubFeatureFlags.shared.telemetryEnabled }
            if telemetryEnabled {
                print("[RATE_GATE_CHECK] isReverse=\(isReverse) isStop=\(isStop) StableScrubMode=\(StableScrubMode.enabled)")
            }
            if isReverse || isStop {
                rateGateDenials[clipID] = 0
            } else if StableScrubMode.enabled {
                rateGateDenials[clipID] = 0
            } else {
                // Check rate-gating with equality fix (>=)
                var elapsed: TimeInterval = .infinity
                var minInterval: TimeInterval = 0
                if let lastTime = lastDecodeTime[clipID] {
                    elapsed = now - lastTime
                    if urgentAdmission {
                        minInterval = 0
                    } else if direction == .forward {
                        minInterval = config.forwardMinInterval
                    } else {
                        let absVelocity = abs(velocityFPS)
                        let threshold = config.reverseVelocityFreeThreshold
                        let normalized = max(0.0, 1.0 - min(absVelocity, threshold) / max(threshold, 0.001))
                        minInterval = config.reverseMinInterval * normalized
                    }

                    var shouldGate = elapsed < minInterval

                    if shouldGate {
                        let consecutive = rateGateDenials[clipID, default: 0] + 1
                        let cooldownOK: Bool
                if let lastOverride = lastRateGateOverride[clipID] {
                            cooldownOK = now - lastOverride >= config.reverseRateGateOverrideCooldown
                        } else {
                            cooldownOK = true
                        }
                        let canOverride = clipInflight == 0 && globalInflight < globalAllowance && !urgentAdmission && consecutive >= config.reverseRateGateOverrideCount && cooldownOK
                        if canOverride {
                            shouldGate = false
                            rateGateDenials[clipID] = 0
                            lastRateGateOverride[clipID] = now
                        } else {
                            rateGateDenials[clipID] = consecutive
                        }
                    } else {
                        rateGateDenials[clipID] = 0
                    }

                    if shouldGate && isCriticalPurpose && warmShort {
                        shouldGate = false
                        rateGateDenials[clipID] = 0
                    }

                    if shouldGate {
                        await logAdmission(clipID: clipID,
                                           admitted: false,
                                           reason: "rate_gate",
                                           clipInflight: clipInflight,
                                           globalInflight: globalInflight,
                                           kind: admissionKind,
                                           criticalUsed: reverseSlot != nil)
                        let currentGlobal = globalInflight
                        await MainActor.run {
                            ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                                              purpose: purpose,
                                                                              admitted: false,
                                                                              clipInflight: clipInflight,
                                                                              globalInflight: currentGlobal,
                                                                              nearReverseRepair: isNearReverseRepair)
                        }
                        await recordAdmissionStats(clipID: clipID,
                                                   nearGrantedDelta: 0,
                                                   farDeniedDelta: urgentAdmission ? 0 : 1,
                                                   preemptedDelta: urgentAdmission ? 1 : 0,
                                                   inflight: clipInflight,
                                                   global: currentGlobal)

                        Task { @MainActor in
                            // TEMP: Always log for debugging
                            ScrubTelemetry.shared.logCoalesce(ScrubTelemetry.CoalesceLog(
                                timestamp: now,
                                minIntervalMS: minInterval * 1000,
                                sinceLastMS: elapsed * 1000,
                                decision: "skip",
                                equalityFix: config.useEqualityFix
                            ))
                        }
                        
                        return AdmissionResult(
                            admitted: false,
                            reason: "rate_gate",
                            clipInflight: clipInflight,
                            globalInflight: globalInflight
                        )
                    }
                } else {
                    rateGateDenials[clipID] = 0
                }
            }
        } else {
            rateGateDenials[clipID] = 0
        }

        if let reverseSlot, StableScrubMode.enabled {
            var slot = reverseSlots[clipID] ?? ReverseSlot()
            let capacity = capacity(for: reverseSlot)
            let allowSteal: Bool
            switch reverseSlot {
            case .deadline:
                allowSteal = true
                slot.release(owner: .repair)
            case .reverse:
                allowSteal = urgentAdmission
            case .repair:
                allowSteal = false
            }
            if !slot.tryAcquire(owner: reverseSlot,
                                capacity: capacity,
                                allowSteal: allowSteal) {
                reverseSlots[clipID] = slot
                await logAdmission(clipID: clipID,
                                   admitted: false,
                                   reason: "reverse_slot",
                                   clipInflight: clipInflight,
                                   globalInflight: globalInflight,
                                   kind: admissionKind,
                                   criticalUsed: true)
                let currentGlobal = globalInflight
                let ownerLabel = reverseSlot.rawValue
                await MainActor.run {
                    ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                                      purpose: purpose,
                                                                      admitted: false,
                                                                      clipInflight: clipInflight,
                                                                      globalInflight: currentGlobal,
                                                                      nearReverseRepair: isNearReverseRepair)
                    print("[ADMISSION_BLOCK] \(ownerLabel) waits reverse slot")
                }
                await recordAdmissionStats(clipID: clipID,
                                           nearGrantedDelta: 0,
                                           farDeniedDelta: urgentAdmission ? 0 : 1,
                                           preemptedDelta: urgentAdmission ? 1 : 0,
                                           inflight: clipInflight,
                                           global: globalInflight)
                return AdmissionResult(admitted: false,
                                       reason: "reverse_slot",
                                       clipInflight: clipInflight,
                                       globalInflight: globalInflight)
            }
            reverseSlots[clipID] = slot
        }

        // Admitted!
        var admissionReason = deadlineBypass ? "stop_bypass" : "admitted"
        if globalOverrideUsed {
            admissionReason = "global_override"
        }
        await logAdmission(clipID: clipID,
                           admitted: true,
                           reason: admissionReason,
                           clipInflight: clipInflight,
                           globalInflight: globalInflight,
                           kind: admissionKind,
                           criticalUsed: (reverseSlot != nil) || globalOverrideUsed)
        let currentGlobal = globalInflight
        await MainActor.run {
            ReverseScrubDiagnostics.shared.logAdmissionDetail(clipID: clipID,
                                                              purpose: purpose,
                                                              admitted: true,
                                                              clipInflight: clipInflight,
                                                              globalInflight: currentGlobal,
                                                              nearReverseRepair: isNearReverseRepair)
        }
        await recordAdmissionStats(clipID: clipID,
                                   nearGrantedDelta: urgentAdmission ? 1 : 0,
                                   farDeniedDelta: 0,
                                   preemptedDelta: 0,
                                   inflight: clipInflight,
                                   global: currentGlobal)

        return AdmissionResult(
            admitted: true,
            reason: admissionReason,
            clipInflight: clipInflight,
            globalInflight: globalInflight
        )
    }
    
    /// Marks decode as started (increments counters).
    func markStarted(clipID: UUID,
                     direction: ScrubCoordinator.ScrubDirection,
                     isDeadline: Bool = false) {
        perClipInflight[clipID, default: 0] += 1
        globalInflight += 1
        if direction == .reverse {
            let count = reverseInflightPerClip[clipID, default: 0] + 1
            reverseInflightPerClip[clipID] = count
            if count == 1 {
                startBurst(clipID: clipID)
                reverseStartTime[clipID] = CFAbsoluteTimeGetCurrent()
            }
        }
        if isDeadline {
            startBurst(clipID: clipID)
        }
    }

    /// Marks decode as completed (decrements counters).
    func markCompleted(clipID: UUID,
                       direction: ScrubCoordinator.ScrubDirection) {
        if let count = perClipInflight[clipID], count > 0 {
            perClipInflight[clipID] = count - 1
        }
        if globalInflight > 0 {
            globalInflight -= 1
        }
        lastDecodeTime[clipID] = CFAbsoluteTimeGetCurrent()
        rateGateDenials[clipID] = 0
        lastRateGateOverride[clipID] = nil
        if direction == .reverse {
            let next = (reverseInflightPerClip[clipID] ?? 1) - 1
            if next > 0 {
                reverseInflightPerClip[clipID] = next
            } else {
                reverseInflightPerClip[clipID] = nil
                reverseStartTime[clipID] = nil
            }
        }
        releaseReverseSlot(for: clipID)
    }

    /// Releases the reservation for a decode that failed or timed out before completion.
    func onDecodeFailureOrTimeout(clipID: UUID,
                                  direction: ScrubCoordinator.ScrubDirection) {
        if let count = perClipInflight[clipID], count > 0 {
            let next = count - 1
            perClipInflight[clipID] = next > 0 ? next : nil
        }
        if globalInflight > 0 {
            globalInflight -= 1
        }
        rateGateDenials[clipID] = 0
        lastRateGateOverride[clipID] = nil
        if direction == .reverse {
            let next = (reverseInflightPerClip[clipID] ?? 1) - 1
            if next > 0 {
                reverseInflightPerClip[clipID] = next
            } else {
                reverseInflightPerClip[clipID] = nil
                reverseStartTime[clipID] = nil
            }
        }
        releaseReverseSlot(for: clipID)
    }
    
    /// Starts burst mode for clip (allows higher inflight for brief period).
    func startBurst(clipID: UUID) {
        burstStartTime[clipID] = CFAbsoluteTimeGetCurrent()
    }
    
    /// Resets state for clip.
    func reset(clipID: UUID) {
        perClipInflight[clipID] = 0
        lastDecodeTime[clipID] = nil
        burstStartTime[clipID] = nil
        stats[clipID] = nil
        rateGateDenials[clipID] = nil
        lastRateGateOverride[clipID] = nil
        reverseInflightPerClip[clipID] = nil
        reverseSlots[clipID] = nil
    }

    func forceReleaseForClip(_ clipID: UUID, reason: String) async {
        perClipInflight[clipID] = 0
        reverseInflightPerClip[clipID] = nil
        releaseReverseSlot(for: clipID)
        let telemetryEnabled = await MainActor.run { ScrubFeatureFlags.shared.telemetryEnabled }
        if telemetryEnabled {
            print("[REV_SLOT_RESET] clip=\(clipID.uuidString.prefix(8)) reason=\(reason)")
        }
    }
    
    /// Resets all state.
    func resetAll() {
        perClipInflight.removeAll()
        globalInflight = 0
        lastDecodeTime.removeAll()
        burstStartTime.removeAll()
        stats.removeAll()
        rateGateDenials.removeAll()
        lastRateGateOverride.removeAll()
        reverseInflightPerClip.removeAll()
        reverseSlots.removeAll()
    }

    func reverseInflightCount(for clipID: UUID) -> Int {
        reverseInflightPerClip[clipID] ?? 0
    }
    
    // MARK: - Private Methods
    
    /// Checks if clip is in burst mode.
    private func isInBurst(clipID: UUID, now: CFAbsoluteTime) -> Bool {
        guard let burstStart = burstStartTime[clipID] else { return false }
        let elapsed = now - burstStart
        return elapsed < config.burstDuration
    }
    
    /// Logs admission decision.
    private func logAdmission(clipID: UUID,
                              admitted: Bool,
                              reason: String,
                              clipInflight: Int,
                              globalInflight: Int,
                              kind: String,
                              criticalUsed: Bool) async {
        await MainActor.run {
            // TEMP: Always log for debugging
            ScrubTelemetry.shared.logAdmission(ScrubTelemetry.AdmissionLog(
                timestamp: CFAbsoluteTimeGetCurrent(),
                clipID: clipID,
                clipInflight: clipInflight,
                globalInflight: globalInflight,
                denied: !admitted,
                reason: reason,
                kind: kind,
                criticalUsed: criticalUsed
            ))
        }
    }

    func releaseReverseSlotOnCutEdge(clipID: UUID, reason: String) {
        let clipTag = clipID.uuidString.prefix(8)
        let hadSlot = reverseSlots[clipID]?.isHeld ?? false
        releaseReverseSlot(for: clipID)
        if hadSlot {
            print("[ADMISSION_RELEASE_ON_CUT_EDGE] released=true reason=\(reason) clip=\(clipTag)")
        } else {
            print("[ADMISSION_RELEASE_ON_CUT_EDGE] released=true reason=\(reason) clip=\(clipTag) note=already-free")
        }
    }

    private func recordAdmissionStats(clipID: UUID,
                                      nearGrantedDelta: Int,
                                      farDeniedDelta: Int,
                                      preemptedDelta: Int,
                                      inflight: Int,
                                      global: Int) async {
        var entry = stats[clipID] ?? AdmissionStats()
        entry.nearGranted += nearGrantedDelta
        entry.farDenied += farDeniedDelta
        entry.preempted += preemptedDelta
        stats[clipID] = entry

        await MainActor.run {
            ReverseScrubDiagnostics.shared.updateAdmissionStats(clipID: clipID,
                                                                nearGrantedDelta: nearGrantedDelta,
                                                                farDeniedDelta: farDeniedDelta,
                                                                preemptedDelta: preemptedDelta,
                                                                inflight: inflight,
                                                                global: global)
        }
    }

    private func admissionKind(for purpose: String) -> String {
        if purpose.contains("lz") {
            return "lz"
        }
        if purpose.contains("pred") || purpose == "now" {
            return "pred"
        }
        return "other"
    }

    private func releaseReverseSlot(for clipID: UUID, owner: ReverseSlotOwner? = nil) {
        guard var slot = reverseSlots[clipID] else { return }
        slot.release(owner: owner)
        if slot.isHeld {
            reverseSlots[clipID] = slot
        } else {
            reverseSlots[clipID] = nil
        }
    }

    private func capacity(for owner: ReverseSlotOwner) -> Int {
        switch owner {
        case .reverse:
            return max(1, config.reverseCriticalSlotsPerClip)
        case .repair:
            return max(1, config.reverseRepairSlotCapacity)
        case .deadline:
            return max(1, config.reverseDeadlineSlotCapacity)
        }
    }
}
