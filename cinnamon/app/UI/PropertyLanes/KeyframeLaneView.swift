import SwiftUI

struct KeyframeLaneView: View {
    @ObservedObject var track: EnhancedKeyframeTrack
    @State private var selectedKeyframeIDs: Set<UUID> = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    for keyframe in track.keyframes {
                        let x = CGFloat(keyframe.time / max(1, track.keyframes.last?.time ?? 1)) * geo.size.width
                        let y = geo.size.height * (1 - CGFloat(keyframe.value / (track.propertyLane.valueRange.upperBound)))
                        path.addEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    }
                }
                .stroke(track.propertyLane.colorTag, lineWidth: 1)

                ForEach(track.keyframes) { keyframe in
                    let x = CGFloat(keyframe.time / max(1, track.keyframes.last?.time ?? 1)) * geo.size.width
                    let y = geo.size.height * (1 - CGFloat(keyframe.value / (track.propertyLane.valueRange.upperBound)))
                    Circle()
                        .fill(selectedKeyframeIDs.contains(keyframe.id) ? Color.accentColor : track.propertyLane.colorTag)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: y)
                        .onTapGesture {
                            toggleSelection(for: keyframe)
                        }
                }
            }
        }
    }

    private func toggleSelection(for keyframe: EnhancedKeyframe) {
        if selectedKeyframeIDs.contains(keyframe.id) {
            selectedKeyframeIDs.remove(keyframe.id)
        } else {
            selectedKeyframeIDs.insert(keyframe.id)
        }
    }
}
