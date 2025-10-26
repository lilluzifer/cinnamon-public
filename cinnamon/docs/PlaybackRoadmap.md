# Playback Modernisation Roadmap

## 2. GOP-bewusste Seek-/Scrub-Logik
- **Ist**: `VideoSource` nutzt `AVAssetReader` mit `timeRange`, aber ohne Keyframe-Wissen; `needsSeek` vergleicht nur `currentStart`.
- **Schritte**:
  1. Beim Import `AVAsset` inspizieren (`loadSampleData`, `segmentForTrackTimeRange`) und Keyframe-Tabelle (`[CMTime]`) in `Clip.metadata` hinterlegen.
  2. Erweiterung `ClipMetadata`: neues Feld `keyframeTableURL` oder eingebettete Liste (ggf. komprimiert).
  3. `VideoSource` lädt Tabelle lazily, sucht per Binary-Search den Keyframe ≤ Zielzeit, setzt `timeRange` auf Keyframe, dekodiert P/B-Frames bis Wunschzeit.
  4. Für Scrub (rate 0) Reader warm halten: `readerOutput.copyNextSampleBuffer()` in Warmup-Task, Frames in `FrameQueue` belassen.
  5. Tests: Assets mit langen GOPs (GoPro, DJI) → Seek-Latenz & Frame-Accuracy messen.

## 3. Mehrstufiges Proxy- & Cache-System
- **Ist**: Clips referenzieren Original-Dateien über `assetRef`; kein Proxy.
- **Schritte**:
  1. Anforderungen definieren (Auflösungen, Codecs, Farbräume) → Config `ProxyProfile`.
  2. `ClipImporter` erweitert: Für jedes Profil Transcode-Job (VideoToolbox/FFmpeg) anstoßen, Ergebnis in Cache (`~/Library/Application Support/cinnamon/Proxies/...`).
  3. `Clip.metadata` bekommt Proxy-Matrix (`[ProxyProfile: URL]` + Hash + Dimensions).
  4. `VideoSource` initialisiert passend zur gewählten Qualität; `TransportController` + UI erhalten Toggle (Auto/Force Original/Proxy).
  5. Optional: Standbild-Proxy (PosterFrame) für Offline-Segmente.
  6. Tests: Playback/Seek/Export mit Proxy vs. Original, Verifikation dass Audio in Sync bleibt.

## 4. Größerer Puffer & Multi-Thread-Decoder
- **Ist**: `FramePipeline.FrameRing` Kapazität 3, Single Task pro Clip.
- **Schritte**:
  1. `FrameRing` Capacity konfigurierbar (z. B. 12), speichert zusätzlich `decodePTS`, `hostArrival`.
  2. `PlaybackDecodeScheduler`: Actor mit Prioritäts-Queue (aktiv sichtbare Clips, Lookahead, Proxy-Preload) + N Worker Tasks (DispatchQueue global qos `userInteractive`).
  3. Jobs ziehen `VideoSource`->`copyFrame`, pushen in Ring. `decodeIntervals` dynamisch anhand `PlaybackClock.rate`, BufferFill.
  4. Telemetrie: BufferFill%, Drops, DecodeDuration. UI Overlay / Debug Panel.
  5. Transport entscheidet bei Buffer-Unterlauf: Frame drop vs. Clock-Stall (abhängig von Wiedergaberate/Latency Budget).

## 5. Audio-Pipeline Modernisieren
- **Ist**: `TimelineAudioMixer` liest `AVAudioFile`, schedult Segment live, kein Prebuffer.
- **Schritte**:
  1. Pre-Decode pro Clip in `AVAudioPCMBuffer` (Segment-Granular, z. B. 0.5 s) → Livespeicher / Disk-Cache.
  2. `PlaybackClock` -> Mixer: On `play`, plane mehrere Buffer mit `AVAudioTime(hostTime:...)` (siehe Design-Dokument).
  3. Gap-Handling: Stille-Buffer planen statt komplettes Stoppen.
  4. Audio-Scrub: Spezielle Engine-Graph (separate PlayerNode, TimePitch Node) mit kurzer Buffer-Länge, optional Pitch-Shifting.
  5. Rate-Änderungen (0.5×/2×): Einsatz `AVAudioUnitTimePitch` oder Offline-Resampling.
  6. Gapless Übergänge: Überblenden/StopTime matching.

## 6. Telemetrie & Tools
- **Module**: `PlaybackTelemetry` (Singleton/Actor) mit Pipelines für Clock, Audio, Video, Buffer.
- **Events**: `clockState`, `audioRenderTime`, `videoFramePresented`, `bufferFill`, `gapEntry/Exit`.
- **UI/CLI**: Debug HUD (SwiftUI Overlay) + CLI (`cin-playback-diag`) für Logs/CSV Export.
- **Alerts**: Schwellen (Drift > 3 ms, Buffer < 20 %, Decode Error). Integrate mit Logger (OSLog).

## 7. Continuous Testing
- **Kurzfristig**: UI-Test Harness mit Skripten (Play/Pause/Seek/Scrub). Automatisches Capture (Screen Recording + Log) & Assert (FrameCount, Clock Drift).
- **Mittelfristig**: Unit Tests für `PlaybackClock`, `PlaybackDecodeScheduler`, `TimelineAudioMixer` (mit Fake Drivers).
- **Langfristig**: Performance Benchmarks (Metal Render FPS, CPU, GPU, Buffer Fill). Integration in CI (custom macOS runners, asset subsets).
