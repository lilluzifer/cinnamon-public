import SwiftUI

struct TimelinePanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        PanelContainer(panel: .timeline, viewModel: viewModel) {
            VStack(spacing: 0) {
                controlBar
                    .padding(8)
                Divider()
                TimelineUILayout(controller: viewModel.timelineController,
                                  layers: viewModel.layers,
                                  layerDuration: viewModel.timelineController.composition.duration,
                                  selectedLayerIDs: viewModel.selectedLayerIDs,
                                  onLayerTap: { layerID in
                                      viewModel.selectLayer(layerID)
                                  },
                                  onBringForward: { viewModel.bringSelectedLayersForward() },
                                  onSendBackward: { viewModel.sendSelectedLayersBackward() },
                                  onBringToFront: { viewModel.bringSelectedLayersToFront() },
                                  onSendToBack: { viewModel.sendSelectedLayersToBack() },
                                  onReorderLayers: { ids, index in
                                      viewModel.reorderLayers(movingLayerIDs: ids, targetDisplayIndex: index)
                                  })
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.splitClipAtPlayhead()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                viewModel.deleteClipAtPlayhead()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.setWorkInAtPlayhead()
            } label: {
                Label("Set In", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.setWorkOutAtPlayhead()
            } label: {
                Label("Set Out", systemImage: "arrow.up.to.line")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.clearWorkArea()
            } label: {
                Label("Clear Work", systemImage: "xmark")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 12)

            Button {
                viewModel.liftWorkArea()
            } label: {
                Label("Lift", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.extractWorkArea()
            } label: {
                Label("Extract", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.undoTimeline()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 12)

            if viewModel.isScrubbing {
                Text("Scrubbing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .controlSize(.small)
        .disabled(viewModel.layers.isEmpty)
    }
}
