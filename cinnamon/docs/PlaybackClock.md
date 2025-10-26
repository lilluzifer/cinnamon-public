# Playback Clock & Scheduler Design

## Kontext
Die aktuelle Transport-Pipeline basiert auf einem `DispatchSourceTimer`, der die UI mit ~240 Hz tastet und daraus den `latchedTime` im `TransportController` ableitet. Audio und Video folgen diesem Wert opportunistisch. Ziel ist ein Master-Clock-Konzept, das Decoder-Zeiten als führende Quelle nutzt, Audio-/Video-Pfade synchronisiert und UI/Tools konsistent informiert.

## Ist-Zustand: Zeitquellen & Kopplung
- **TimelineTicker** (`app/Playback/TimelineTicker.swift`): rechnet `CACurrentMediaTime()` in Timeline-Zeit um, erzeugt alle ~4 ms einen Tick und ruft den Transport (`handleTimelineTick`).
- **TransportController** (`app/Transport/TransportController.swift`): hält `latchedTime` / `latchedPlaybackRate`, berechnet Segmentsprünge, verwaltet `gapTimer`, aktualisiert Audio (`updateAudioForCurrentTime`) und `FrameClock`.
- **AudioMixer** (`app/Transport/TimelineAudioMixer.swift`): reschedult pro Tick PlayerNodes basierend auf `timelineTime`, spielt sofort, kennt keinen globalen Zeitbezug.
- **FramePipeline** (`app/Playback/FramePipeline.swift`): nutzt `TransportController.shared.currentTime` als Pull-Quelle, dekodiert opportunistisch zwei Targets (Now / Lookahead) und cached Frames.
- **FrameClock** (`app/Playback/FrameClock.swift`): Broadcast-only, übernimmt Werte aus dem Transport und dient ViewModels/Renderer als Beobachter.

## Schwachstellen & Risiken
1. **Ticker-driven statt Sample-driven** – Durch `DispatchSourceTimer` entstehen Drift und Jitter relativ zu Audio/Decoder-Zeit. Audio re-schedult häufig, statt kontinuierlich zu laufen.
2. **Kein gemeinsamer Zeitbase** – Audio (AVAudioEngine), Video (Decoder-Ausgabe), UI (Ticker) und mögliche AVFoundation-Komponenten laufen auf unterschiedlichen Host-Zeiten.
3. **Hoher Scheduling-Overhead** – `TimelineAudioMixer.activate` wird pro Tick aufgerufen, stoppt/plant Nodes neu; Scrub/Seek invalidiert komplette Pipelines.
4. **Fehlende Driftmessung** – Es gibt keine Telemetrie, die Host-Zeit, Decoder-PTS oder Audio-Render-Zeit gegenüberstellt.
5. **Decoder-Pipeline Pull-only** – VideoDecoder folgt Transportzeit, baut keinen Vorhalte-Puffer auf einer unabhängigen Clock auf.

## Zielbild: PlaybackClock
### Grundprinzip
Eine `PlaybackClock` abstrahiert über einen `CMTimebase`, der an eine physikalische Quelle (z. B. AudioEngine oder Decoder PTS) gekoppelt ist. Alle Teilsysteme lesen ausschließlich aus dieser Clock. Der Transport verwaltet nach wie vor Business-Logik (Segmentwechsel, Warmup), delegiert aber die fortlaufende Zeit zu `PlaybackClock`.

### Verantwortlichkeiten
1. **State-Verwaltung** (`PlaybackClock.State`): `currentTime`, `rate`, `isPlaying`, `hostTime`, `driftEstimate`.
2. **Driver-Interface** (`PlaybackClockDriver`): liefert `ClockSample`s (PTS + optional HostTime). Beispiele: `AudioClockDriver`, `VideoClockDriver`, `ExternalClockDriver` (z. B. für `AVSampleBufferDisplayLayer`).
3. **Observers**: `TransportController`, `FrameClockBridge`, Telemetrie. Subscription via AsyncSequence oder Combine-Publisher.
4. **Rate-/Seek-Steuerung**: Transport fordert Play/Pause/Seek an, Clock aktualisiert Timebase und emittiert neuen State.

### API-Skizze
```swift
actor PlaybackClock {
    struct State { let time: TimeInterval; let rate: Double; let isPlaying: Bool; let hostTime: UInt64; let drift: TimeInterval }
    func attach(driver: PlaybackClockDriver)
    func detachDriver()
    func play(from time: TimeInterval, rate: Double)
    func pause(at time: TimeInterval? = nil)
    func seek(to time: TimeInterval)
    func stateStream() -> AsyncStream<State>
    func currentState() -> State
}
```

### Kopplung Audio
- `TimelineAudioMixer` erhält eine `PlaybackClock`-Referenz.
- Beim Planen erstellt der Mixer `AVAudioPCMBuffer`-Sequenzen für Segmente (Vorhaltezeit > 250 ms).
- `AVAudioPlayerNode.scheduleBuffer` nutzt `AVAudioTime(hostTime: clockState.hostTime + offset)` statt sofortigem Play.
- Ein `AudioClockDriver` liest `AVAudioEngine.outputNode.lastRenderTime` + SampleTime, erzeugt daraus `ClockSample` und füttert die Clock kontinuierlich. Bei Engine-Stops übernimmt die Clock den letzten HostTime + Rate 0.

### Kopplung Video
- Decoder (z. B. `AVPlayerItemVideoOutput` oder eigener `AVAssetReader`) liefern PTS → `VideoClockDriver` kann als Fallback dienen, wenn Audio stumm.
- Rendering nutzt `PlaybackClock.currentState().time` als Ziel; `FramePipeline` ersetzt direkten Zugriff auf `TransportController`.
- Für `AVSampleBufferDisplayLayer`: `clock.controlTimebase = playbackClock.timebase` ermöglicht automatische Sync.

### UI & Ticker Bridge
- Ersetzt `TimelineTicker` durch `PlaybackClockDisplayLink`, der `CADisplayLink` oder `DispatchSourceTimer` nur zum Polling/Invalidate benutzt, aber Zeitwerte aus der Clock liest.
- `TransportController` reagiert auf Clock-State-Stream, hält `latchedTime` für Segmentlogik aktuell, löst Preloading anhand Clock-Zeit aus.

### Zustandsübergänge
1. **Play**: Transport ruft `clock.play(from: latchedTime, rate: desiredRate)`. Clock startet Timebase, AudioDriver plant Buffer → ClockState aktualisiert `isPlaying`.
2. **Seek**: Transport ruft `clock.pause(at:)`, setzt `latchedTime`, instructs drivers to flush, ruft `clock.seek(to:)`. Decoder/Audiomixer warmup → Clock wartet auf `Driver.ready` bevor `play`.
3. **Pause**: `clock.pause(at:)` friert Timebase ein, AudioDriver stoppt Engine.

## Integrationsplan (Phasen)
1. **Instrumentation & Telemetrie**
   - Clock-Prototyp, der weiterhin `CACurrentMediaTime()` nutzt, aber bereits State-Stream & Telemetrie bietet.
   - Metriken: TickInterval, Drift zwischen Ticker & Audio (falls vorhanden), Frame-Latency.
2. **PlaybackClock Core**
   - Implementiere `PlaybackClock`, `ClockSample`, `PlaybackClockDriver`.
   - Füge `PlaybackClock.shared` hinzu, ersetze direkte `frameClock.update`-Aufrufe durch Clock-Observer.
3. **Transport Refactor**
   - `TransportController` hält nur noch `latchedTime` als Cache, subscribt Clock.
   - Entferne `TimelineTicker`, ersetze durch `PlaybackClockDisplayLink` (UI) + `PlaybackClock`-callbacks.
   - Gap-/Segmentlogik bleibt, aber Progression basiert auf Clock.
4. **Audio Integration**
   - Erweitere `TimelineAudioMixer` um Vorhalte-Puffer (PCM-Buffers pro Segment).
   - Implementiere `AudioClockDriver` (Engine render callback → ClockSample).
   - Plane Buffer relativ zur Clock; kein Re-Scheduling on tick.
5. **Video Scheduler**
   - `FramePipeline.decodeLoop` nutzt Clock-State (Zeit + Rate) und priorisiert Frames dort.
   - Optional: Worker-Pool/Lookahead (siehe Multi-Thread Decoder Roadmap).
6. **Failover & Testing**
   - Ohne Audio → `VideoClockDriver` übernimmt (Decoder PTS + hostTime via `CMSampleBufferGetOutputPresentationTimeStamp`).
   - Telemetrie vergleicht Driver-Quellen, meldet Drift > Threshold.

## Test & Monitoring
- **Unit Tests**: `PlaybackClock` Parameteränderungen, Seek -> Invariant (time monotonic when playing, freeze when paused).
- **Integration**: Simulierte Drivers (Audio/Video) in TestHarness, vergleiche Transport `latchedTime` mit Clock.
- **Telemetry**: Log `clockState`, `AudioEngine.renderTime`, `VideoPTS`, Gap-Hits.
- **A/B Drifts**: automatischer Alarm bei |AudioPTS - Clock.time| > 3 ms über > 100 ms.

## Aktueller Stand
- `PlaybackClock` implementiert (`app/Playback/PlaybackClock.swift`) mit Play/Pause/Seek/Align und Sample-Ingestion inklusive Driftberechnung.
- `TimelineTicker` liest die Zeit ausschließlich aus der Clock (`app/Playback/TimelineTicker.swift`).
- `TransportController` synchronisiert `playbackClock` bei allen Zustandswechseln und füttert Videoframes als Korrektur-Samples ein (`app/Transport/TransportController.swift`).
- `TimelineAudioMixer` nutzt Host-Time-Scheduling der Clock, um PlayerNodes ohne Tick-Restarts zu starten (`app/Transport/TimelineAudioMixer.swift`).
- Telemetrie via `PlaybackTelemetry` (aktivierbar mit `CIN_PLAYBACK_TELEMETRY=1`) protokolliert Clock-Drift (`app/Playback/PlaybackTelemetry.swift`).
- Unit-Tests decken zentrale Clock-Invarianten ab (`app/Tests/TimelineSelfTests.swift`).

## Offene Fragen
- Wie soll Priorität zwischen Audio- und Video-Driver gewählt werden? Vorschlag: Audio als Primary, Video als Backup; definierter Fallback bei Stille.
- Benötigen wir variable Rate (0.5× / 2×) über AudioPitch-Shifting? → Einfluss auf `AudioClockDriver` (Time Stretching vs. Resampling).
- Wie integrieren wir bestehende Warmup-Tasks (z. B. `tickerWarmupTask`)? Wahrscheinlich als Pre-Roll vor `clock.play`.
