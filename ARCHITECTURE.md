# Architecture Overview - Back Scrubbing System

This document describes the architecture of the back scrubbing (reverse scrubbing) system in Cinnamon.

## Architecture Layers

### Core Coordinators

**ScrubCoordinator** (`cinnamon/app/Playback/ScrubCoordinator.swift:61`, `:98`)
- Starts/stops scrub operations
- Maintains velocity history
- Triggers all workers with 120ms lookahead prediction

**IntegratedScrubPipeline** (`cinnamon/app/Playback/IntegratedScrubPipeline.swift:221`)
- Bundles Phase-3 decoder and Phase-2 control logic
- Manages clip-specific decoders
- Handles GOP managers, admission control, and proxy states

### Prediction & Targeting

**VelocityPredictor** (`cinnamon/app/Playback/VelocityPredictor.swift:41`)
- Smooths real timeline movement using EMA (Exponential Moving Average)
- Provides `t_pred` (predicted time)
- Delivers adaptive window for landing zones

**LandingZoneManager** (`cinnamon/app/Playback/LandingZoneManager.swift:33`)
- Forms direction-dependent warm regions
- Emphasizes reverse direction
- Includes repair mode for large deltas

**GOPCoalescingManager** (`cinnamon/app/Playback/GOPCoalescingManager.swift:40`)
- Decides reuse/retarget/cancel per GOP (Group of Pictures)
- Prevents decoupling during fast direction changes

**Feature Flags** (`cinnamon/app/Playback/ScrubFeatureFlags.swift:12`)
- Enables/disables all phase optimizations
- Controls watchdogs and heuristics

---

## Reverse Scrubbing Flow

### 1. Begin Scrub
**Location:** `IntegratedScrubPipeline.swift:222`

- Increments epoch number
- Resets admission and velocity
- Creates decoder + GOP manager per clip

### 2. Update Scrub
**Location:** `IntegratedScrubPipeline.swift:294`

- Fetches prediction
- Calculates landing zones
- Starts clip-wise reverse target finding

### 3. Pre-Decode Checks
**Location:** `IntegratedScrubPipeline.swift:435`

- Reads warm counts from transport cache
- Sets cold-reset trigger if neither forward nor backward frames are available

### 4. End Gesture
**Location:** `IntegratedScrubPipeline.swift:320`

- Enforces mandatory decodes
- Performs deadline decodes
- Complete cleanup including proxy release

### 5. End Scrub
**Location:** `ScrubCoordinator.swift:125`

- Adds ungated deadline decode
- Ensures exact frame ready within ≤66ms

### 6. Cleanup
**Location:** `IntegratedScrubPipeline.swift:360`

- Resets histories, error counters, and proxy overrides
- Ensures clean start for next scrub operation

---

## Target & Frame Management

### Decode Targets
**Location:** `IntegratedScrubPipeline.swift:1603`

- Quantizes times to frame indices
- Prioritizes reverse frames behind `t_pred`
- Strictly limits forward slots

### Cursor System
**Location:** `IntegratedScrubPipeline.swift:1869`

- Recognizes direction changes
- Detects large timeline jumps and drift
- Keeps reverse indices stable

### Landing Zone Points
**Locations:**
- `LandingZoneManager.swift:164`
- `ReverseScrubDiagnostics.swift:461`

- Checks against warm frames in cache
- Logs hits and fill levels for diagnostics

### Cold Reset
**Location:** `IntegratedScrubPipeline.swift:448`

Triggered when buffers are dry:
- Cancels GOP jobs
- Releases admission
- Completely resets decoder

### Repair Decodes
**Location:** `IntegratedScrubPipeline.swift:1375`

- Fills missing frames
- Clamps delta windows
- Cleans cache history behind target

---

## Admission & Resources

### Admission Control
**Location:** `AdmissionController.swift:106`

- Mixes global limits with per-clip slots
- Provides reverse-specific critical slots
- Includes override logic

### Equality Thresholds
**Location:** `ReverseScrubDiagnostics.swift:134`

- Uses explicit `>=` to prevent 25/33ms stall
- Telemetry tracking

### Source Preparation
**Location:** `IntegratedScrubPipeline.swift:1157`

- Adaptively switches between original and spot proxy
- Keeps proxy hits sticky
- Warms random access zones

### Watchdogs
**Location:** `IntegratedScrubPipeline.swift:595`

Cleans hanging reverse decodes:
- Force-releases all admission slots
- Complete VT rebuild
- GOP cancellation

### Decode Task Scheduling
**Location:** `IntegratedScrubPipeline.swift:97`

- Creates job IDs for each request
- Optional reverse watchdog
- Clean termination via `finishDecodeJob`

---

## Decoder & Infrastructure

### EnhancedScrubDecoder
**Location:** `EnhancedScrubDecoder.swift:18`

- Maintains PersistentReader/VT session
- IDR preroll of 8-12 frames
- Zero-copy pixel path for fast reverse decodes

### Frame Decoding
**Location:** `EnhancedScrubDecoder.swift:1677`

`decodeFrameSimple`:
- Uses random access cache
- Stage timing
- Admission feedback
- Writes buffers to transport cache

### Frame Caching
**Locations:**
- `IntegratedScrubPipeline.swift:852`
- `IntegratedScrubPipeline.swift:1541`

- Decoded frames stored via `TransportController.shared.cacheFrame`
- Primary and history stores
- History pruned behind target via `pruneHistory` for reverse

### GOP Decisions
**Location:** `GOPCoalescingManager.swift:92`

- Registered at start/update
- Cancels old tasks on retargets
- Tracks reuse statistics

---

## Diagnostics & Telemetry

### Reverse-Specific Logs
**Locations:**
- `ReverseScrubDiagnostics.swift:206`
- `ReverseScrubDiagnostics.swift:483`

Coverage includes:
- Coalescing decisions
- Admission control
- Target selection
- Landing zone hits
- Ring buffer fill levels
- Decoder paths

### Warm Sequence Logging
**Locations:**
- `ReverseScrubDiagnostics.swift:437`
- `ReverseScrubDiagnostics.swift:489`

Helps identify reverse bottlenecks:
- Missing warm frames
- Proxy switching
- Color space issues
- Immediate admission events

### Watchdog Telemetry
**Location:** `IntegratedScrubPipeline.swift:121`

- Logs telemetry events on reverse timeouts
- Triggers optional cleanup

### Diagnostic Reports
**Location:** `ReverseScrubDiagnostics.swift:564`

`generateReport` summarizes:
- Equality gate statistics
- GOP reuse metrics
- Landing zone hits
- Ring buffer dips
- Boundary violations
- Predictor status
- Admission quotas

---

## Key Files Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| Scrub Coordinator | `ScrubCoordinator.swift` | 61, 98, 125 |
| Main Pipeline | `IntegratedScrubPipeline.swift` | 221, 294, 320, 360, 435, 1603 |
| Velocity Prediction | `VelocityPredictor.swift` | 41 |
| Landing Zones | `LandingZoneManager.swift` | 33, 164 |
| GOP Management | `GOPCoalescingManager.swift` | 40, 92 |
| Admission Control | `AdmissionController.swift` | 106 |
| Enhanced Decoder | `EnhancedScrubDecoder.swift` | 18, 1677 |
| Feature Flags | `ScrubFeatureFlags.swift` | 12 |
| Diagnostics | `ReverseScrubDiagnostics.swift` | Multiple |

---

## Current Issues (Help Needed!)

### 🔴 CRITICAL: Admission Deadlock

**⚠️ See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for complete analysis and proposed solutions.**

**Root Cause:** VT-12785 errors cause decode tasks to fail without releasing admission slots, leading to:
- Admission counter stuck at `10/8` (over limit!)
- `pending_cleanup=false` so watchdog never triggers
- Landing zone starves (`warmBehind=0`, `window_fill%=0.0`)
- Renderer stuck on stale "future_frame" placeholders
- Both forward AND backward scrubbing break after first error

**Key Problem Files:**
- `AdmissionController.swift:106` - Counter leak on task failure
- `IntegratedScrubPipeline.swift:595` - Watchdog doesn't trigger
- `EnhancedScrubDecoder.swift:1677` - VT-12785 not handled
- `IntegratedScrubPipeline.swift:97` - Tasks don't always call `finishDecodeJob`

**Proposed Solutions:**
1. Force cleanup on VT-12785 errors
2. Make stuck-task timeout more aggressive (50ms instead of 150ms)
3. Add admission counter validation/failsafe
4. Guarantee task completion with `defer` blocks

### Other Known Problems

1. **Multi-layer complexity**
   - NLE with multiple clips/layers
   - One stuck layer stalls entire composition
   - Need per-clip timeout + global failsafe

2. **Stale frames on direction change**
   - Cache invalidation timing issues
   - Related to admission deadlock

3. **IDR frame alignment**
   - VT-12785 often triggered by GOP boundary issues
   - Need better IDR detection/preroll

### Areas to Investigate

- **Admission Control Logic** - Counter leak on error paths
- **GOP Coalescing** - Interaction with stuck tasks
- **Landing Zone Prediction** - Starvation when admission blocked
- **VT Session Management** - Should rebuild on -12785?
- **Task Lifecycle** - Guaranteed cleanup on all error paths
- **Multi-clip coordination** - Per-clip vs global admission

---

## Architecture Decisions

### Why 120ms Lookahead?
- Balances prediction accuracy with resource usage
- Provides enough time for GOP decode without over-predicting

### Why Phase-3 + Phase-2?
- Phase-3: Advanced decoder with persistent VT sessions
- Phase-2: Control logic for admission and resource management
- Separation of concerns improves debugging

### Why Landing Zones?
- Pre-warm frames in predicted regions
- Reduces cold-start latency when scrubbing
- Direction-aware to optimize for reverse

### Why GOP Coalescing?
- Prevents redundant decodes during rapid direction changes
- Reuses in-flight GOP decodes when target changes
- Reduces VideoToolbox session churn

---

## Contributing

If you're helping debug the reverse scrubbing issues, please:

1. Enable diagnostics: `Cmd+Shift+D`
2. Focus on the files listed in the Key Files Reference
3. Review the diagnostic logs for pattern recognition
4. Check telemetry output in `ReverseScrubDiagnostics`

Thank you for helping improve Cinnamon! 🙏
