import SwiftUI

struct PropertyLaneView: View {
    let lane: PropertyLane
    @ObservedObject var track: EnhancedKeyframeTrack
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(lane.colorTag).frame(width: 8, height: 8)
                Text(lane.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $track.isVisible).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 8)

            KeyframeLaneView(track: track)
                .frame(height: track.height)
                .background(Color.black.opacity(0.05))
                .cornerRadius(6)
        }
        .padding(.vertical, 4)
    }
}
