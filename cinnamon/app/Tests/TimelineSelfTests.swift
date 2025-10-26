import Foundation
import SwiftUI
import CoreMedia

enum TimelineSelfTests {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CIN_RUN_TESTS"] == "1" else { return }
        var failures: [String] = []

        runClockTests(&failures)

        runTest("Sanitizer clamps matte cycles") {
            let track = Track(stackIndex: 0, kind: .video, name: "Layer", muted: false, solo: false, locked: false, color: .blue)
            let aID = UUID()
            let bID = UUID()

            var a = Clip(id: aID,
                         name: "A",
                         assetRef: "a.mov",
                         srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                         dstStart: 0,
                         transformRef: track.id,
                         matteMode: .alpha,
                         matteSourceID: bID)
            var b = Clip(id: bID,
                         name: "B",
                         assetRef: "b.mov",
                         srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                         dstStart: 0,
                         transformRef: track.id,
                         matteMode: .alpha,
                         matteSourceID: aID)

            let composition = Composition(frameRate: 24,
                                          duration: 1,
                                          tracks: [track],
                                          clips: [a, b],
                                          markers: [],
                                          workArea: nil)

            let controller = TimelineController(initial: composition)
            controller.updateComposition(composition)
            let sanitized = controller.composition
            let problematic = sanitized.clips.filter { $0.matteMode != .none || $0.matteSourceID != nil }
            if !problematic.isEmpty {
                let summary = problematic.map { clip in
                    "clip=\(clip.id) mode=\(clip.matteMode) source=\(String(describing: clip.matteSourceID))"
                }.joined(separator: "; ")
                throw TestError.failure("Expected matte cycle to be cleared, got [\(summary)]")
            }
        } catch: { failures.append($0) }

        runTest("Playback mapper hides matte draw segments") {
            let trackA = Track(stackIndex: 1, kind: .video, name: "Fill", muted: false, solo: false, locked: false, color: .red)
            let trackB = Track(stackIndex: 2, kind: .video, name: "Matte", muted: false, solo: false, locked: false, color: .blue)

            let matteClip = Clip(name: "Matte",
                                 assetRef: "matte.mov",
                                 srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                 dstStart: 0,
                                 transformRef: trackB.id,
                                 hideAsRender: true)
            let fillClip = Clip(name: "Fill",
                                assetRef: "fill.mov",
                                srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                dstStart: 0,
                                transformRef: trackA.id,
                                matteMode: .alpha,
                                matteSourceID: matteClip.id)

            let composition = Composition(frameRate: 24,
                                          duration: 1,
                                          tracks: [trackB, trackA],
                                          clips: [matteClip, fillClip],
                                          markers: [],
                                          workArea: nil)

            let playback = TimelinePlaybackMapper.segments(for: composition)
            guard let slice = playback.compositeTimeline.first else {
                throw TestError.failure("Expected composite slice")
            }
            if !slice.orderedSegments.contains(where: { $0.clip?.id == fillClip.id }) {
                throw TestError.failure("Fill clip missing from ordered segments")
            }
            if slice.orderedSegments.contains(where: { $0.clip?.id == matteClip.id }) {
                throw TestError.failure("Matte clip should be hidden from draw list")
            }
            if slice.mattes[fillClip.id]?.clip.id != matteClip.id {
                throw TestError.failure("Matte attachment not resolved")
            }
        } catch: { failures.append($0) }

        runTest("Sanitizer enforces minimum duration") {
            let track = Track(stackIndex: 0, kind: .video, name: "Layer", muted: false, solo: false, locked: false, color: .green)
            var clip = Clip(name: "Short",
                            assetRef: "short.mov",
                            srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.01, preferredTimescale: 600)),
                            dstStart: 0,
                            transformRef: track.id)
            clip.srcRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 0.0001, preferredTimescale: 600))

            let timebase = FrameTimebase(frameRate: 24)
            let sanitized = ClipSanitizer.sanitize(clip, frameTimebase: timebase)
            let minimum = timebase.frameDuration.seconds * clip.effectiveSpeed
            if sanitized.srcRange.duration.seconds < minimum {
                throw TestError.failure("Clip duration not clamped to minimum frame")
            }
        } catch: { failures.append($0) }

        runTest("Matte mode permutations propagate") {
            let trackA = Track(stackIndex: 1, kind: .video, name: "Fill", muted: false, solo: false, locked: false, color: .red)
            let trackB = Track(stackIndex: 2, kind: .video, name: "Matte", muted: false, solo: false, locked: false, color: .blue)

            let matteClip = Clip(name: "Matte",
                                 assetRef: "matte.mov",
                                 srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                 dstStart: 0,
                                 transformRef: trackB.id)

            for mode in TrackMatteMode.allCases where mode != .none {
                let fillClip = Clip(name: "Fill",
                                    assetRef: "fill.mov",
                                    srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
                                    dstStart: 0,
                                    transformRef: trackA.id,
                                    matteMode: mode,
                                    matteSourceID: matteClip.id)

                let composition = Composition(frameRate: 24,
                                              duration: 1,
                                              tracks: [trackB, trackA],
                                              clips: [matteClip, fillClip],
                                              markers: [],
                                              workArea: nil)

                let playback = TimelinePlaybackMapper.segments(for: composition)
                guard let slice = playback.compositeTimeline.first else {
                    throw TestError.failure("Expected slice for mode \(mode)")
                }
                if slice.mattes[fillClip.id]?.mode != mode {
                    throw TestError.failure("Matte mode \(mode) not preserved in composite")
                }
            }
        } catch: { failures.append($0) }

        if failures.isEmpty {
            print("[Tests] ✅ All timeline tests passed")
            exit(0)
        } else {
            failures.forEach { fputs("[Tests] ❌ \($0)\n", stderr) }
            exit(1)
        }
    }

    private static func runClockTests(_ failures: inout [String]) {
        runTest("PlaybackClock advances with host time") {
            var hostTime: CFTimeInterval = 100
            let clock = PlaybackClock.makeTestingClock { hostTime }
            clock.reset()
            clock.play(from: 10, rate: 1)

            hostTime += 2
            let advanced = clock.currentTime(at: hostTime)
            guard abs(advanced - 12) <= 1e-6 else {
                throw TestError.failure("Expected 12.0, got \(advanced)")
            }
        } catch: { failures.append($0) }

        runTest("PlaybackClock pause freezes time") {
            var hostTime: CFTimeInterval = 50
            let clock = PlaybackClock.makeTestingClock { hostTime }
            clock.reset()
            clock.play(from: 5, rate: 1)

            hostTime += 1
            guard abs(clock.currentTime(at: hostTime) - 6) <= 1e-6 else {
                throw TestError.failure("Expected 6.0 at t+1")
            }

            clock.pause()
            hostTime += 10
            guard abs(clock.currentTime(at: hostTime) - 6) <= 1e-6 else {
                throw TestError.failure("Clock should freeze after pause")
            }
        } catch: { failures.append($0) }

        runTest("PlaybackClock ingests samples and records drift") {
            var hostTime: CFTimeInterval = 200
            let clock = PlaybackClock.makeTestingClock { hostTime }
            clock.reset()
            clock.play(from: 0, rate: 1)

            hostTime += 1
            let sample = PlaybackClock.Sample(time: 1.01,
                                              hostTime: hostTime,
                                              rate: 1,
                                              isPlaying: true,
                                              source: .video)
            clock.ingest(sample: sample)
            let state = clock.currentState()

            guard abs(state.time - 1.01) <= 1e-6 else {
                throw TestError.failure("Expected time 1.01, got \(state.time)")
            }
            guard abs(state.drift - 0.01) <= 1e-6 else {
                throw TestError.failure("Expected drift 0.01, got \(state.drift)")
            }
            guard state.source == .video else {
                throw TestError.failure("Expected source .video, got \(state.source)")
            }
        } catch: { failures.append($0) }
    }

    private static func runTest(_ name: String, _ body: () throws -> Void, catch handler: (String) -> Void) {
        do {
            try body()
        } catch {
            handler("\(name): \(error)")
        }
    }

    private enum TestError: Error, CustomStringConvertible {
        case failure(String)

        var description: String {
            switch self {
            case .failure(let message): return message
            }
        }
    }
}
