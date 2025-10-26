import Foundation

/// Phase 2.1: GOP-based coalescing & retarget.
/// Reuses work within same GOP, cancels only when switching GOPs.
actor GOPCoalescingManager {
    
    // MARK: - Types
    
    struct JobState {
        let gopKey: TimeInterval  // IDR PTS
        var targetPTS: TimeInterval
        var task: Task<Void, Never>
        let startTime: CFAbsoluteTime
        var retargetCount: Int = 0
    }
    
    enum Decision {
        case reuse(retarget: Bool)  // Same GOP, optionally retarget
        case cancel(reason: String)  // Different GOP, cancel old job
        case start  // No existing job
    }
    
    // MARK: - Properties
    
    private let clipID: UUID
    private let config: ScrubFeatureFlags.Config
    private var currentJob: JobState?
    private var gopReuseCount: Int = 0
    private var gopCancelCount: Int = 0
    
    // MARK: - Initialization
    
    init(clipID: UUID, config: ScrubFeatureFlags.Config) {
        self.clipID = clipID
        self.config = config
    }
    
    // MARK: - Public Methods
    
    /// Decides whether to reuse, retarget, or cancel current job.
    func decide(newGOPKey: TimeInterval, newTarget: TimeInterval) -> Decision {
        print("[GOP_DECIDE] StableScrubMode.enabled=\(StableScrubMode.enabled) hasJob=\(currentJob != nil)")
        guard let job = currentJob else {
            return .start
        }
        
        // Same GOP?
        if abs(job.gopKey - newGOPKey) < 0.001 {  // 1ms tolerance
            gopReuseCount += 1

            // Check if target changed significantly
            let targetDelta = abs(job.targetPTS - newTarget)
            // CRITICAL: Use tight threshold (~10ms = 1/4 frame @ 24fps) to keep decoder close to user position
            // During reverse scrubbing, loose thresholds cause "future_frame" rejections and lag
            // Trade-off: Some task restarts vs. stale decoder targets
            let shouldRetarget = targetDelta > 0.010  // 10ms = ~1/4 frame @ 24fps
            
            // Log GOP coalesce
            Task { @MainActor in
                // TEMP: Always log for debugging
                ScrubTelemetry.shared.logGOPCoalesce(ScrubTelemetry.GOPCoalesceLog(
                    timestamp: CFAbsoluteTimeGetCurrent(),
                    gopKey: newGOPKey,
                    reused: true,
                    retarget: shouldRetarget,
                    canceled: false
                ))
            }
            
            return .reuse(retarget: shouldRetarget)
        } else {
            // Different GOP - cancel old job
            gopCancelCount += 1
            
            // Log GOP coalesce
            Task { @MainActor in
                // TEMP: Always log for debugging
                ScrubTelemetry.shared.logGOPCoalesce(ScrubTelemetry.GOPCoalesceLog(
                    timestamp: CFAbsoluteTimeGetCurrent(),
                    gopKey: newGOPKey,
                    reused: false,
                    retarget: false,
                    canceled: true
                ))
            }
            
            return .cancel(reason: "new_gop")
        }
    }
    
    /// Reserves a job slot before the decode task is created.
    func reserveJob(gopKey: TimeInterval, targetPTS: TimeInterval) {
        if let existing = currentJob {
            print("[GOP_RESERVE_CANCEL] gop=\(existing.gopKey) target=\(String(format: "%.3f", existing.targetPTS))")
            existing.task.cancel()
        }
        let placeholder = Task.detached {}
        currentJob = JobState(
            gopKey: gopKey,
            targetPTS: targetPTS,
            task: placeholder,
            startTime: CFAbsoluteTimeGetCurrent()
        )
        print("[GOP_RESERVE] gop=\(gopKey) target=\(String(format: "%.3f", targetPTS))")
    }

    /// Registers (or updates) the active job with the real task handle.
    func registerJob(gopKey: TimeInterval, targetPTS: TimeInterval, task: Task<Void, Never>) {
        if let existing = currentJob, abs(existing.gopKey - gopKey) < 0.001 {
            existing.task.cancel()
            currentJob = JobState(
                gopKey: gopKey,
                targetPTS: targetPTS,
                task: task,
                startTime: existing.startTime,
                retargetCount: existing.retargetCount
            )
            print("[GOP_REGISTER_UPDATE] gop=\(gopKey) target=\(String(format: "%.3f", targetPTS))")
        } else {
            currentJob?.task.cancel()
            currentJob = JobState(
                gopKey: gopKey,
                targetPTS: targetPTS,
                task: task,
                startTime: CFAbsoluteTimeGetCurrent()
            )
            print("[GOP_REGISTER_NEW] gop=\(gopKey) target=\(String(format: "%.3f", targetPTS))")
        }
    }
    
    /// Cancels the current job.
    func cancelJob() {
        currentJob?.task.cancel()
        currentJob = nil
    }
    
    /// Clears the current job (when completed).
    func clearJob() {
        currentJob = nil
    }
    
    /// Returns GOP reuse statistics.
    func getStats() -> (reuseCount: Int, cancelCount: Int, reuseRate: Double) {
        let total = gopReuseCount + gopCancelCount
        let reuseRate = total > 0 ? Double(gopReuseCount) / Double(total) : 0.0
        return (gopReuseCount, gopCancelCount, reuseRate)
    }
    
    /// Resets statistics.
    func resetStats() {
        gopReuseCount = 0
        gopCancelCount = 0
    }
}
