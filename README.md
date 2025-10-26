# Cinnamon - Video Editor for macOS

A video editor built with SwiftUI for macOS, featuring advanced playback capabilities and timeline editing.

## ⚠️ Current Status: Seeking Help

This project is in active development. **I'm currently experiencing issues with backward scrubbing performance and would appreciate any help from the community.**

### What Works ✅
- Smooth forward scrubbing
- Normal playback with good performance
- GOP (Group of Pictures) analysis
- Frame extraction and caching
- Timeline navigation
- Layer-based composition

### Known Issues ❌

**🔴 CRITICAL DEADLOCK** - See [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- **Admission counter deadlock** - VT-12785 errors cause slots to wedge at 10/8
- **Landing zone starvation** - `warmBehind=0`, `window_fill%=0.0`
- **Renderer stuck** - Shows only stale "future_frame" placeholders
- **Both forward AND backward scrubbing break** after first VT error

**Additional Issues:**
- Multi-layer composition complexity (NLE with multiple clips)
- Watchdog doesn't trigger when `pending_cleanup=false`
- Failed decode tasks don't release admission slots

## Tech Stack

- **Language:** Swift
- **UI Framework:** SwiftUI
- **Video Processing:**
  - VideoToolbox (VTDecompressionSession)
  - AVFoundation
  - Core Media
- **Graphics:** Metal
- **Target:** macOS 14.0+

## Architecture Overview

**📚 See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed system architecture and reverse scrubbing flow.**

### Playback System
The playback system consists of several key components:

- **`ScrubCoordinator`** - Orchestrates scrub operations with 120ms lookahead
- **`IntegratedScrubPipeline`** - Main scrubbing pipeline with Phase-3 decoder
- **`EnhancedScrubDecoder`** - Advanced frame decoder with persistent VT sessions
- **`VelocityPredictor`** - Predicts timeline movement for pre-warming
- **`LandingZoneManager`** - Direction-aware frame pre-warming
- **`GOPCoalescingManager`** - Prevents redundant decodes on direction changes
- **`TransportController`** - Transport controls and state management
- **`FrameHistoryManager`** - Manages decoded frame history
- **`GOPAnalyzer`** - Analyzes H.264 GOP structure

### Key Features
- Persistent VT decompression sessions for performance
- GOP-aware frame decoding with reuse logic
- Velocity-based prediction and landing zones
- Multi-threaded frame extraction
- Adaptive quality management
- Admission control with reverse-specific critical slots
- Comprehensive telemetry and diagnostics

## Getting Started

**📖 See [QUICKSTART.md](QUICKSTART.md) for detailed build and usage instructions.**

### Requirements
- Xcode 15.0 or later
- macOS 14.0 (Sonoma) or later
- Swift 5.9 or later
- A H.264 video file for testing

### Quick Build

```bash
# Clone the repository
git clone https://github.com/lilluzifer/cinnamon-public.git
cd cinnamon-public

# Open in Xcode
open cinnamon.xcodeproj

# Build and run (Cmd+R)
# Then import a video file to test scrubbing
```

## Project Structure

```
cinnamon/
├── app/
│   ├── Playback/              # Video playback engine
│   │   ├── IntegratedScrubPipeline.swift
│   │   ├── EnhancedScrubDecoder.swift
│   │   ├── TransportController.swift
│   │   ├── FrameHistoryManager.swift
│   │   └── GOPAnalyzer.swift
│   ├── Timeline/              # Timeline management
│   ├── Rendering/             # Metal rendering
│   ├── UI/                    # SwiftUI views
│   ├── Transport/             # Playback controls
│   └── Telemetry/             # Diagnostics and logging
└── Resources/
```

## Contributing

I'm actively looking for help, especially with:
- VideoToolbox performance optimization
- Backward scrubbing implementation strategies
- H.264 decoder best practices
- Frame caching strategies

If you have experience with professional video playback systems or VideoToolbox, your insights would be invaluable!

### Areas Needing Attention

1. **Backward Scrubbing Performance** (`IntegratedScrubPipeline.swift:245-450`)
   - Lag spikes when scrubbing backwards
   - Frame cache invalidation issues

2. **VT Error -12785** (`EnhancedScrubDecoder.swift:180-220`)
   - Occasional decoder errors during rapid scrubbing
   - IDR frame alignment problems

3. **Frame Staleness** (`FrameHistoryManager.swift`)
   - Old frames occasionally displayed when direction changes

## Diagnostics

The project includes comprehensive telemetry:
- Scrub performance metrics
- Frame decode timing
- Cache hit/miss rates
- GOP structure analysis

Enable diagnostics in `ScrubFeatureFlags.swift`.


## Contact

For questions or collaboration, please open an issue on GitHub.

---

**Note:** This project represents my learning journey in video engineering. The code includes extensive documentation and diagnostic tools that might be helpful for others learning about video playback systems on macOS.
