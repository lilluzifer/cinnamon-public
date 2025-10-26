# Known Issues - Critical Deadlock in Reverse Scrubbing

## 🔴 CRITICAL: Admission Deadlock via VT-12785 Errors

### Symptom
Both backward AND forward scrubbing become laggy or completely stuck, showing only stale "future_frame" placeholders in the renderer.

### Root Cause Analysis

#### 1. VT Error -12785 Cascade
```
FigExportCommon err=-12785
DECODE_ASSET … target≈4.93 s
```

Multiple VideoToolbox decode tasks fail with error `-12785` (`kVTVideoDecoderBadDataErr`), typically when:
- Decodes jump far ahead of the playhead
- Rapid direction changes occur
- GOP boundaries are misaligned

#### 2. Admission Slots Wedged
```
REVERSE_INFLIGHT_LIMIT clip… active=10 max=8 pending_cleanup=false
```

**Problem:**
- Admission counter shows `10/8` - MORE tasks in-flight than allowed!
- `pending_cleanup=false` means watchdog never triggers
- New reverse decodes are rejected: "no admission slots available"
- Slots stay occupied by **dead/failed tasks** that never cleared their counters

#### 3. Landing Zone Starvation
```
warmBehind=0
WARM_SEQ warm=[]
window_fill%=0.0
```

Because admission is blocked:
- No new frames can be decoded
- Landing zone remains completely empty
- `t_pred ≈ 2.68s` but NO frames in reverse window
- Renderer has nothing to show except old frames

#### 4. Renderer Stuck
```
future_frame with swap disabled
frame ages climbing past 250 ms
```

- Renderer keeps re-presenting a frame that's **ahead** of the reverse target
- No fresh reverse content arrives
- Frame age grows unbounded (250ms+)

#### 5. Transport Cache Evidence
```
Cache frames: 2.744, 2.827, 2.911, 2.994, 3.036s
Requested: 2.67s
```

Only forward frames get cached while nothing lands near the requested reverse target.

---

## Technical Details

### Deadlock Sequence

1. **Initial State:** Forward scrubbing works fine
2. **Direction Change:** User scrubs backward
3. **VT-12785 Errors:** Some decode tasks fail (often due to IDR misalignment)
4. **Counter Leak:** Failed tasks don't decrement admission counters
5. **Admission Wedged:** `active=10 max=8` - over limit!
6. **Watchdog Disabled:** `pending_cleanup=false` so watchdog never runs
7. **Pipeline Stalled:** No new decodes admitted → landing zone empty → renderer starves

### Why Watchdog Doesn't Trigger

**Location:** `IntegratedScrubPipeline.swift:595`

```swift
if pending_cleanup == false {
    // Watchdog logic...
    forceCompleteReset()
    releaseAllAdmissionSlots()
}
```

The watchdog **only** runs when `pending_cleanup=true`, but that flag is never set when tasks fail with VT-12785.

### Affected Components

| Component | File | Issue |
|-----------|------|-------|
| Admission Control | `AdmissionController.swift:106` | Counter leak on VT errors |
| Decode Tasks | `IntegratedScrubPipeline.swift:97` | Failed tasks don't call `finishDecodeJob` |
| Watchdog | `IntegratedScrubPipeline.swift:595` | Never triggers (`pending_cleanup=false`) |
| VT Session | `EnhancedScrubDecoder.swift:1677` | VT-12785 errors not handled |
| Landing Zone | `LandingZoneManager.swift:164` | Starves due to admission block |

---

## Proposed Solutions

### Solution 1: Aggressive VT-12785 Handling ⭐ (Recommended)

When VT-12785 error occurs:

```swift
// In EnhancedScrubDecoder.swift:1677
if status == kVTVideoDecoderBadDataErr {
    // Immediate cleanup
    forceCompleteReset()
    releaseAdmissionSlot(for: taskID)

    // Log for diagnostics
    ReverseScrubDiagnostics.logVTError(status, target: target)

    // Optionally: Rebuild VT session
    rebuildVTSession()
}
```

### Solution 2: Stuck-Task Detection (Timeout-Based)

Make watchdog more aggressive:

```swift
// In IntegratedScrubPipeline.swift:595
let STUCK_TASK_TIMEOUT = 100.0 // ms (currently too lenient)

if taskAge > STUCK_TASK_TIMEOUT {
    // Force cleanup even if pending_cleanup=false
    forceCompleteReset()
    releaseAllAdmissionSlots()

    ReverseScrubDiagnostics.logWatchdogTrigger(taskAge: taskAge)
}
```

### Solution 3: Admission Counter Failsafe

Add periodic counter validation:

```swift
// In AdmissionController.swift
func validateCounters() {
    if active > max {
        // CRITICAL: More tasks than allowed!
        print("⚠️ Admission counter leak detected: \(active)/\(max)")

        // Force reset
        active = 0
        releaseAllSlots()
    }
}
```

### Solution 4: Task Completion Guarantees

Ensure **every** decode task calls `finishDecodeJob`:

```swift
// In IntegratedScrubPipeline.swift:97
func scheduleDecodeTask(...) {
    defer {
        // ALWAYS release, even on error
        finishDecodeJob(taskID)
    }

    // ... decode logic ...
}
```

---

## Multi-Layer Complexity

**Note:** This is an NLE (Non-Linear Editor) with **multiple layers/clips**.

Each layer can have its own:
- Decoder instance
- Admission slots
- GOP manager
- Landing zone

The deadlock can occur **per-clip** or **globally**:
- If one clip's decoder wedges, it blocks its admission slots
- Other clips may continue working
- Renderer waits for ALL layers → one stuck layer stalls entire output

**Multi-clip amplification:**
- With N clips, N× chance of VT-12785 error
- One stuck clip = entire composition stalls
- Need per-clip timeout + global failsafe

---

## Reproduction Steps

1. **Load a video** (H.264, multi-layer timeline)
2. **Scrub forward** - works fine initially
3. **Scrub backward rapidly** - trigger VT-12785 errors
4. **Continue scrubbing** - admission wedges at 10/8
5. **Observe:** Landing zone stays empty, renderer stuck on "future_frame"
6. **Result:** Both forward AND backward scrubbing now broken

---

## Diagnostic Logs

### What to Look For

Enable diagnostics (`Cmd+Shift+D`) and look for:

```
✅ Normal: REVERSE_INFLIGHT_LIMIT active=3 max=8 pending_cleanup=false
❌ Stuck:  REVERSE_INFLIGHT_LIMIT active=10 max=8 pending_cleanup=false

✅ Normal: WARM_SEQ warm=[2.5, 2.6, 2.7] window_fill%=85.0
❌ Stuck:  WARM_SEQ warm=[] window_fill%=0.0

✅ Normal: cached_frame t=2.67s age=15ms
❌ Stuck:  future_frame age=250ms swap_disabled
```

### Key Metrics

- **Admission active > max** → Counter leak
- **warmBehind=0** → Starvation
- **window_fill%=0.0** → Landing zone empty
- **VT-12785 errors** → Root cause
- **frame age > 200ms** → Renderer stalled

---

## Workarounds (Until Fixed)

### User Workaround
1. **Quit and relaunch** the app
2. **Scrub more slowly** to avoid rapid direction changes
3. **Use lower resolution proxies** if available

### Developer Workaround
1. **Reduce `REVERSE_INFLIGHT_MAX`** in `AdmissionController.swift` (e.g., 8 → 4)
2. **Lower `STUCK_TASK_TIMEOUT`** in watchdog (150ms → 50ms)
3. **Add counter validation** every update cycle
4. **Force VT session rebuild** on any -12785 error

---

## Help Needed

If you have experience with:
- **VideoToolbox error handling** (especially -12785)
- **Admission control / semaphore patterns**
- **VT session lifecycle management**
- **Async task cleanup guarantees**

Please review:
- `AdmissionController.swift:106` - Counter management
- `IntegratedScrubPipeline.swift:595` - Watchdog logic
- `EnhancedScrubDecoder.swift:1677` - VT error handling
- `IntegratedScrubPipeline.swift:97` - Task scheduling

Any insights would be greatly appreciated! 🙏

---

## Status

- **Discovered:** 2025-10-26
- **Severity:** CRITICAL (blocks all scrubbing after first error)
- **Affected:** Both forward and backward scrubbing
- **Fix:** In progress - investigating solutions 1-4 above
