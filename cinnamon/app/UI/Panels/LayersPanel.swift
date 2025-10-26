import SwiftUI
import UniformTypeIdentifiers

struct LayersPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var dropIndicatorIndex: Int?

    var body: some View {
        PanelContainer(panel: .layers, viewModel: viewModel) {
            VStack(spacing: 0) {
                PanelHeader(title: "Layers", panel: .layers, viewModel: viewModel)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        headerRow

                        LayerDropZone(index: 0,
                                      highlightedIndex: $dropIndicatorIndex,
                                      onDrop: handleDrop)

                        ForEach(Array(viewModel.layers.enumerated()), id: \.element.id) { index, layer in
                            let sources = viewModel.matteSourceOptions(for: layer.id)
                            let aboveOption = viewModel.layerAboveOption(for: layer.id)
                            LayerRowView(layer: layer,
                                         isSelected: viewModel.selectedLayerIDs.contains(layer.id),
                                         labelColor: color(for: layer.labelColor),
                                         onTap: { viewModel.selectLayer(layer.id) },
                                         onToggleVisibility: { viewModel.toggleLayerVisibility(layer.id) },
                                         onToggleSolo: { viewModel.toggleLayerSolo(layer.id) },
                                         onToggleLock: { viewModel.toggleLayerLock(layer.id) },
                                         onSelectBlendMode: { viewModel.setLayerBlendMode(layer.id, mode: $0) },
                                         onMatteChange: { mode, selection in
                                             viewModel.setClipMatte(clipID: layer.activeClipID, mode: mode, selection: selection)
                                         },
                                         onToggleHide: { hide in
                                             viewModel.setClipHideAsRender(clipID: layer.activeClipID, hide: hide)
                                         },
                                         availableSources: sources,
                                         layerAboveOption: aboveOption,
                                         dragPayload: dragPayload(for: layer),
                                         dropIndex: index,
                                         highlightedIndex: $dropIndicatorIndex,
                                         onDrop: handleDrop)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)

                            LayerDropZone(index: index + 1,
                                          highlightedIndex: $dropIndicatorIndex,
                                          onDrop: handleDrop)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func handleDrop(_ payload: LayerDragPayload, index: Int) {
        dropIndicatorIndex = nil
        viewModel.reorderLayers(movingLayerIDs: payload.layerIDs, targetDisplayIndex: index)
    }

    private var headerRow: some View {
        HStack {
            Text("Layer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            HStack(spacing: columnSpacing) {
                Text("Vis")
                Text("Solo")
                Text("Lock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: switchColumnWidth, alignment: .trailing)
            Text("Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: modeColumnWidth, alignment: .leading)
            Text("Matte")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: matteColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func dragPayload(for layer: LayerSummary) -> LayerDragPayload? {
        guard !layer.isLocked else { return nil }
        let selection = viewModel.selectedLayerIDs
        let orderedSelection = viewModel.layers
            .map(\.id)
            .filter { selection.contains($0) }

        let ids = selection.contains(layer.id) ? orderedSelection : [layer.id]
        return LayerDragPayload(layerIDs: ids)
    }

    private func color(for label: LayerLabelColor) -> Color {
        switch label {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .aqua: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        }
    }
}

private let columnSpacing: CGFloat = 16
private let switchColumnWidth: CGFloat = 110
private let modeColumnWidth: CGFloat = 120
private let matteColumnWidth: CGFloat = 200

private struct LayerRowView: View {
    let layer: LayerSummary
    let isSelected: Bool
    let labelColor: Color
    let onTap: () -> Void
    let onToggleVisibility: () -> Void
    let onToggleSolo: () -> Void
    let onToggleLock: () -> Void
    let onSelectBlendMode: (BlendMode) -> Void
    let onMatteChange: (TrackMatteMode, MatteSourceSelection) -> Void
    let onToggleHide: (Bool) -> Void
    let availableSources: [MatteSourceOption]
    let layerAboveOption: MatteSourceOption?
    let dragPayload: LayerDragPayload?
    let dropIndex: Int
    @Binding var highlightedIndex: Int?
    let onDrop: (LayerDragPayload, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(labelColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(layer.name)
                            .lineLimit(1)
                            .fontWeight(layer.isMatteConsumer ? .semibold : .regular)

                        if layer.isMatteConsumer {
                            Image(systemName: "circle.lefthalf.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .help("Layer uses a track matte")
                        }
                    }

                    if layer.isMatteSource {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(layer.matteTargets) { target in
                                Text("Matte für \(target.name)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: columnSpacing) {
                    LayerSwitchButton(systemName: layer.isVisible ? "eye" : "eye.slash",
                                      isActive: layer.isVisible,
                                      action: onToggleVisibility)
                    LayerSwitchButton(systemName: layer.isSolo ? "person.crop.circle.fill" : "person.crop.circle",
                                      isActive: layer.isSolo,
                                      action: onToggleSolo)
                    LayerSwitchButton(systemName: layer.isLocked ? "lock.fill" : "lock.open",
                                      isActive: layer.isLocked,
                                      action: onToggleLock)
                }
                .frame(width: switchColumnWidth, alignment: .trailing)

                Menu {
                    ForEach(BlendMode.allCases, id: \.self) { mode in
                        Button(mode.displayName) {
                            onSelectBlendMode(mode)
                        }
                        .disabled(layer.blendMode == mode)
                    }
                } label: {
                    Text(layer.blendMode.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: modeColumnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    matteMenu
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if layer.isMatteSource || layer.hideAsRender {
                        Toggle("Hide Matte as Render", isOn: Binding(
                            get: { layer.hideAsRender },
                            set: { onToggleHide($0) }
                        ))
                        .font(.caption)
                        .toggleStyle(.switch)
                        .disabled(layer.activeClipID == nil)
                    }
                }
                .frame(width: matteColumnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .modifier(ConditionalDraggable(payload: dragPayload))
        .dropDestination(for: LayerDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            onDrop(payload, dropIndex)
            return true
        } isTargeted: { isTargeted in
            highlightedIndex = isTargeted ? dropIndex : nil
        }
    }

    private var rowBackground: Color {
        if highlightedIndex == dropIndex {
            return Color.accentColor.opacity(0.25)
        }
        return isSelected ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.04)
    }

    @ViewBuilder
    private var matteMenu: some View {
        Menu {
            Button("None") {
                onMatteChange(.none, .none)
            }
            .disabled(layer.matteMode == .none && layer.matteSelection == .none)

            ForEach(TrackMatteMode.allCases.filter { $0 != .none }, id: \.self) { mode in
                if availableSources.isEmpty, layerAboveOption == nil {
                    Text(mode.displayName)
                        .foregroundColor(.secondary)
                } else {
                    Menu(mode.displayName) {
                        if let above = layerAboveOption {
                            Button("Layer Above (\(above.name))") {
                                onMatteChange(mode, .layerAbove)
                            }
                            .disabled(layer.matteMode == mode && layer.usesLayerAbove)
                        }

                        ForEach(availableSources) { source in
                            Button(source.name) {
                                onMatteChange(mode, .clip(source.id))
                            }
                            .disabled(layer.matteMode == mode && layer.matteSourceClipID == source.id)
                        }
                    }
                }
            }
        } label: {
            Text(matteDisplayName)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(layer.activeClipID == nil)
    }

    private var matteDisplayName: String {
        switch layer.matteMode {
        case .none:
            return TrackMatteMode.none.displayName
        default:
            if layer.usesLayerAbove {
                if let name = layerAboveOption?.name {
                    return "\(layer.matteMode.displayName) · \(name)"
                }
                return "\(layer.matteMode.displayName) · Layer Above"
            }
            if let clipID = layer.matteSourceClipID,
               let source = availableSources.first(where: { $0.id == clipID }) {
                return "\(layer.matteMode.displayName) · \(source.name)"
            }
            return layer.matteMode.displayName
        }
    }
}

private struct ConditionalDraggable: ViewModifier {
    let payload: LayerDragPayload?

    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

private struct LayerSwitchButton: View {
    let systemName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct LayerDropZone: View {
    let index: Int
    @Binding var highlightedIndex: Int?
    let onDrop: (LayerDragPayload, Int) -> Void

    var body: some View {
        Rectangle()
            .fill(highlightedIndex == index ? Color.accentColor.opacity(0.35) : Color.clear)
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: LayerDragPayload.self) { items, _ in
                guard let payload = items.first else { return false }
                onDrop(payload, index)
                return true
            } isTargeted: { isTargeted in
                highlightedIndex = isTargeted ? index : nil
            }
    }
}

private struct LayerDragPayload: Codable, Hashable, Transferable {
    let layerIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private extension BlendMode {
    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .colorDodge: return "Color Dodge"
        case .colorBurn: return "Color Burn"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        }
    }
}

// Removed - displayName is now defined in TimelineDataModel.swift
