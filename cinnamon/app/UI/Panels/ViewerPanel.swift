import SwiftUI
import UniformTypeIdentifiers

struct ViewerPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var showImporter = false
    @State private var showFrameRateSettings = false

    var body: some View {
        PanelContainer(panel: .viewer, viewModel: viewModel) {
            VStack(spacing: 0) {
                PanelHeader(title: "Viewer", panel: .viewer, viewModel: viewModel, trailing: AnyView(zoomControls))
                ZStack(alignment: .topLeading) {
                    PlayerView(viewModel: viewModel)
                        .focusable(false)

                    if viewModel.isGapActive {
                        Rectangle()
                            .fill(Color.black)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                showImporter = true
                            } label: {
                                Label("Video wählen", systemImage: "square.and.arrow.down.on.square")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                viewModel.isAudioMuted.toggle()
                            } label: {
                                Image(systemName: viewModel.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                showFrameRateSettings = true
                            } label: {
                                Image(systemName: "speedometer")
                            }
                            .buttonStyle(.bordered)
                            .help("Frame Rate Settings")

                            Spacer()

                            Text(selectedDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)

                        if viewModel.selectedAssetURL == nil {
                            VStack {
                                Spacer()
                                Text("Wähle ein Video, um die Playback-Pipeline zu testen.")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .audiovisualContent]) { result in
            guard case let .success(url) = result else { return }
            // Start accessing security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                viewModel.setSelectedAsset(url)
                // Note: We keep the resource access open for playback
            } else {
                viewModel.setSelectedAsset(url)
            }
        }
        .sheet(isPresented: $showFrameRateSettings) {
            FrameRateSettingsView()
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Text("Zoom")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Zoom", selection: .constant("Fit")) {
                Text("Fit").tag("Fit")
                Text("100%").tag("100")
                Text("200%").tag("200")
            }
            .labelsHidden()
            .frame(width: 90)
        }
    }

    private var selectedDescription: String {
        if let url = viewModel.selectedAssetURL {
            return "Aktueller Clip: \(url.lastPathComponent)"
        }
        return "Kein Clip ausgewählt"
    }
}
