import SwiftUI

struct ContentView: View {
    @StateObject private var workspace = WorkspaceViewModel()

    var body: some View {
        HSplitView {
            VSplitView {
                ProjectEffectsPanel(viewModel: workspace)
                    .frame(minHeight: 260)
                LayersPanel(viewModel: workspace)
                    .frame(minHeight: 220)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)

            VSplitView {
                ViewerPanel(viewModel: workspace)
                    .frame(minHeight: 260)
                TimelinePanel(viewModel: workspace)
                    .frame(minHeight: 220)
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                // Diagnostics Toggle Button
                Button(action: {
                    workspace.toggleDiagnostics()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: workspace.isDiagnosticsActive ? "waveform.path.ecg" : "waveform.path.ecg.rectangle")
                            .foregroundColor(workspace.isDiagnosticsActive ? .red : .white)
                        Text(workspace.isDiagnosticsActive ? "Stop Diagnostics" : "Start Diagnostics")
                            .font(.caption)
                            .foregroundColor(workspace.isDiagnosticsActive ? .red : .white)
                    }
                    .padding(8)
                    .background(workspace.isDiagnosticsActive ? Color.red.opacity(0.2) : Color.black.opacity(0.5))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Start/Stop A/V Sync Diagnostics (Cmd+Shift+D)")
                
                if workspace.isDiagnosticsActive {
                    Text("Recording... Play for 5s")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                }
            }
            .padding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleDiagnostics"))) { _ in
            workspace.toggleDiagnostics()
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 1200, height: 720)
    }
}
#endif
