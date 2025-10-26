import SwiftUI

struct FrameRateSettingsView: View {
    @ObservedObject private var projectSettings = ProjectSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Project Frame Rate")
                    .font(.headline)

                Text("This affects timeline playback, rendering, and export.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProjectSettings.FrameRate.allCases, id: \.rawValue) { frameRate in
                    HStack {
                        Button(action: {
                            projectSettings.frameRate = frameRate
                        }) {
                            HStack {
                                Image(systemName: projectSettings.frameRate == frameRate ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(projectSettings.frameRate == frameRate ? .accentColor : .secondary)

                                Text(frameRate.description)
                                    .foregroundColor(.primary)

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 8)

            Divider()

            HStack {
                Text("Current: \(projectSettings.frameRate.description)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct FrameRateSettingsWindow: View {
    var body: some View {
        FrameRateSettingsView()
    }
}

#Preview {
    FrameRateSettingsView()
}