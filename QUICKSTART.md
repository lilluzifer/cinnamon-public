# Quick Start Guide

## Building the Project

1. **Clone the repository**
   ```bash
   git clone https://github.com/lilluzifer/cinnamon-public.git
   cd cinnamon-public
   ```

2. **Open in Xcode**
   ```bash
   open cinnamon.xcodeproj
   ```

3. **Build and Run**
   - Select the `cinnamon` scheme
   - Press `Cmd+R` to build and run
   - **Note:** First build may take a few minutes

## Using the App

### Importing a Video

The app doesn't include sample videos. To test it:

1. **Launch the app**
2. **Import a video:**
   - Click "File" → "Import" (or use the file importer in the Viewer panel)
   - Select a `.mov` or `.mp4` file
   - **Recommended:** Use a H.264 encoded video for best compatibility

### Testing Scrubbing

Once a video is loaded:

1. **Forward Scrubbing:**
   - Drag the playhead to the right → Should be smooth ✅

2. **Backward Scrubbing:**
   - Drag the playhead to the left → Currently laggy ❌ (this is the issue I need help with!)

3. **Playback:**
   - Press `Space` to play/pause
   - Should play smoothly ✅

### Enable Diagnostics

To see performance metrics:

1. Press `Cmd+Shift+D` to toggle diagnostics
2. Scrub back and forth to see telemetry data
3. Look for:
   - Frame decode times
   - Cache hit/miss rates
   - VT errors (-12785)

## Known Issues

### Current Problems (Help Needed!)

1. **Backward scrubbing is laggy**
   - Visible lag spikes when dragging left
   - Frame delivery delays

2. **Stale frames**
   - Sometimes old frames appear when changing direction

3. **VT Error -12785**
   - Occasional `kVTVideoDecoderBadDataErr`
   - Usually during rapid direction changes

### What Works

- ✅ Forward scrubbing
- ✅ Normal playback
- ✅ Timeline navigation
- ✅ GOP analysis

## Requirements

- **macOS:** 14.0 (Sonoma) or later
- **Xcode:** 15.0 or later
- **Test Video:** H.264 encoded `.mov` or `.mp4` file

## Recommended Test Videos

For testing, use videos with these characteristics:
- **Codec:** H.264
- **GOP Size:** 12-30 frames
- **Resolution:** 1080p or lower
- **Frame Rate:** 24fps, 30fps, or 60fps

## Code Areas to Review

If you're helping with the scrubbing issue, focus on:

1. **`IntegratedScrubPipeline.swift`** (lines 245-450)
   - Main scrubbing coordinator
   - Direction change handling

2. **`EnhancedScrubDecoder.swift`** (lines 180-220)
   - VT session management
   - Frame decoding logic

3. **`TransportController.swift`**
   - Transport state machine
   - Playhead updates

## Getting Help

If you have questions or want to contribute:
- Open an issue on GitHub
- Tag me in discussions about VideoToolbox or video playback

Thank you for checking out the project! 🙏
