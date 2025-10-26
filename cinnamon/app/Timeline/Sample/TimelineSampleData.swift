import Foundation
import simd
import AVFoundation
import SwiftUI

enum TimelineSampleData {
    private static let sampleLayerID = UUID()
    private static let videoTrackID = UUID()
    private static let audioTrackID = UUID()

    static func demoComposition() -> Composition {
        let compDuration: TimeInterval = 12
        let frameRate: Double = 24
        let videoTrack = Track(id: videoTrackID, stackIndex: 1, kind: .video, name: "Video 1", muted: false, solo: false, locked: false, color: .blue, blendMode: .normal)
        let audioTrack = Track(id: audioTrackID, stackIndex: 0, kind: .audio, name: "Audio 1", muted: false, solo: false, locked: false, color: .red, blendMode: .normal)

        var clips: [Clip] = []
        _ = Transform2D(position: SIMD2<Float>(960, 540), scale: SIMD2<Float>(repeating: 1), rotation: 0, anchor: SIMD2<Float>(repeating: 0.5), opacity: 1, zIndex: 0)

        let clipA = Clip(name: "Clip A",
                         assetRef: "clipA.mov",
                         srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)),
                         dstStart: 0,
                         enabled: true,
                         audioTrackIndex: 0,
                         videoTrackIndex: 0,
                         speed: 1.0,
                         transformRef: videoTrackID)
        let clipB = Clip(name: "Clip B",
                         assetRef: "clipB.mov",
                         srcRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)),
                         dstStart: 6,
                         enabled: true,
                         audioTrackIndex: 0,
                         videoTrackIndex: 0,
                         speed: 1.0,
                         transformRef: videoTrackID)

        clips.append(clipA)
        clips.append(clipB)

        let opacityTrack = TimelineKeyframeTrack(layerID: videoTrackID,
                                                 propertyPath: "transform.opacity",
                                                 keyframes: [
                                                    TimelineKeyframe(time: 0, value: 100),
                                                    TimelineKeyframe(time: 6, value: 100),
                                                    TimelineKeyframe(time: 6.0, value: 0),
                                                    TimelineKeyframe(time: 6.1, value: 100),
                                                    TimelineKeyframe(time: 10, value: 100)
                                                 ])

        return Composition(frameRate: frameRate,
                           duration: compDuration,
                           tracks: [videoTrack, audioTrack],
                           clips: clips,
                           markers: [],
                           workArea: nil,
                           keyframeTracks: [opacityTrack])
    }

    static func demoLayers() -> [LayerSummary] {
        [LayerSummary(id: videoTrackID,
                      name: "Video 1",
                      isVisible: true,
                      isSolo: false,
                      isLocked: false,
                      labelColor: .blue,
                      stackIndex: 1,
                      blendMode: .normal,
                      matteMode: .none),
         LayerSummary(id: audioTrackID,
                      name: "Audio 1",
                      isVisible: true,
                      isSolo: false,
                      isLocked: false,
                      labelColor: .red,
                      stackIndex: 0,
                      blendMode: .normal,
                      matteMode: .none)]
    }
}
