import SwiftUI
import AVFoundation

struct ProjectEffectsPanel: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var selectedTab: ProjectEffectsTab = .project

    enum ProjectEffectsTab: String, CaseIterable {
        case project = "Project"
        case effects = "Effects"
    }

    var body: some View {
        PanelContainer(panel: .projectEffects, viewModel: viewModel) {
            VStack(spacing: 0) {
                PanelHeader(title: "Browser", panel: .projectEffects, viewModel: viewModel)

                Divider()

                // Tab selector with proper constraints
                HStack {
                    Picker("", selection: $selectedTab) {
                        ForEach(ProjectEffectsTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.05))

                Divider()

                // Tab Content with proper clipping
                ZStack {
                    switch selectedTab {
                    case .project:
                        ProjectTabContent(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .effects:
                        EffectsTabContent(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipped()
            }
            .clipped()
        }
    }
}

// Project Tab Content
struct ProjectTabContent: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Project items list
                ForEach(viewModel.projectItems) { item in
                    ProjectItemRow(item: item, viewModel: viewModel)
                }

                if viewModel.projectItems.isEmpty {
                    Text("No media in project")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
            }
            .padding(12)
        }
    }
}

struct ProjectItemRow: View {
    let item: ProjectItem
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 30)
                .overlay {
                    Image(systemName: iconForItemType(item.type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)

                if item.type == .footage {
                    Text("Media")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if item.type == .composition {
                    Text("Comp")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let children = item.childItems {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }

    private func iconForItemType(_ type: ProjectItem.ItemType) -> String {
        switch type {
        case .folder:
            return "folder.fill"
        case .footage:
            return "video.fill"
        case .composition:
            return "rectangle.stack.fill"
        }
    }
}

// Effects Tab Content
struct EffectsTabContent: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let inspector = viewModel.inspectorState {
                    TransformInspectorSection(viewModel: viewModel, inspector: inspector)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MatteInspectorSection(viewModel: viewModel, inspector: inspector)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select a layer with an active clip to view effects and properties.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TransformInspectorSection: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let inspector: ClipInspectorState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transform")
                .font(.headline)

            // Position controls
            HStack(spacing: 12) {
                InspectorNumberRow(title: "Position X",
                                   value: positionXBinding(),
                                   unit: "px")
                InspectorNumberRow(title: "Position Y",
                                   value: positionYBinding(),
                                   unit: "px")
            }

            // Scale controls
            HStack(spacing: 12) {
                InspectorNumberRow(title: "Scale X",
                                   value: scaleXBinding())
                InspectorNumberRow(title: "Scale Y",
                                   value: scaleYBinding())
            }

            // Rotation and Opacity
            HStack(spacing: 12) {
                InspectorNumberRow(title: "Rotation",
                                   value: rotationBinding(),
                                   unit: "°")
                InspectorNumberRow(title: "Opacity",
                                   value: opacityBinding(),
                                   unit: "%")
            }

            // Anchor controls
            InspectorSliderRow(title: "Anchor X",
                               value: anchorXBinding())
            InspectorSliderRow(title: "Anchor Y",
                               value: anchorYBinding())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func positionXBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double(viewModel.inspectorState?.transform.position.x ?? inspector.transform.position.x)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.position.x = Float(newValue)
                }
            }
        )
    }

    private func positionYBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double(viewModel.inspectorState?.transform.position.y ?? inspector.transform.position.y)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.position.y = Float(newValue)
                }
            }
        )
    }

    private func scaleXBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double((viewModel.inspectorState?.transform.scale.x ?? inspector.transform.scale.x) * 100.0)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.scale.x = Float(newValue / 100.0)
                }
            }
        )
    }

    private func scaleYBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double((viewModel.inspectorState?.transform.scale.y ?? inspector.transform.scale.y) * 100.0)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.scale.y = Float(newValue / 100.0)
                }
            }
        )
    }

    private func rotationBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                let radians = viewModel.inspectorState?.transform.rotation ?? inspector.transform.rotation
                return Double(radians * 180.0 / .pi)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.rotation = Float(newValue * .pi / 180.0)
                }
            }
        )
    }

    private func opacityBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                let opacity = viewModel.inspectorState?.transform.opacity ?? inspector.transform.opacity
                return Double(opacity * 100.0)
            },
            set: { newValue in
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.opacity = Float(min(max(newValue / 100.0, 0.0), 1.0))
                }
            }
        )
    }

    private func anchorXBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double(viewModel.inspectorState?.transform.anchor.x ?? inspector.transform.anchor.x)
            },
            set: { newValue in
                let clamped = min(max(newValue, 0.0), 1.0)
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.anchor.x = Float(clamped)
                }
            }
        )
    }

    private func anchorYBinding() -> Binding<Double> {
        Binding<Double>(
            get: {
                Double(viewModel.inspectorState?.transform.anchor.y ?? inspector.transform.anchor.y)
            },
            set: { newValue in
                let clamped = min(max(newValue, 0.0), 1.0)
                viewModel.updateClipTransform(clipID: inspector.clipID) { transform in
                    transform.anchor.y = Float(clamped)
                }
            }
        )
    }
}

private struct MatteInspectorSection: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let inspector: ClipInspectorState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track Matte")
                .font(.headline)

            Picker("Matte Mode", selection: matteModeBinding()) {
                ForEach(TrackMatteMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if matteModeBinding().wrappedValue != .none {
                Picker("Matte Source", selection: matteSourceBinding()) {
                    Text("None").tag(MatteSourceSelection.none)
                    if let above = currentState().layerAboveOption {
                        Text("Layer Above (\(above.name))").tag(MatteSourceSelection.layerAbove)
                    }
                    ForEach(currentState().availableSources) { source in
                        Text(source.name).tag(MatteSourceSelection.clip(source.id))
                    }
                }
                .disabled(currentState().availableSources.isEmpty && currentState().layerAboveOption == nil)
            }

            Toggle("Hide Matte as Render",
                   isOn: Binding(
                       get: { currentState().hideAsRender },
                       set: { viewModel.setClipHideAsRender(clipID: inspector.clipID, hide: $0) }
                   ))
            .disabled(!currentState().isMatteSource && !currentState().hideAsRender)
        }
    }

    private func matteModeBinding() -> Binding<TrackMatteMode> {
        Binding<TrackMatteMode>(
            get: { currentState().matteMode },
            set: { newValue in
                let selection = currentMatteSelection()
                viewModel.setClipMatte(clipID: inspector.clipID, mode: newValue, selection: selection)
            }
        )
    }

    private func matteSourceBinding() -> Binding<MatteSourceSelection> {
        Binding<MatteSourceSelection>(
            get: { currentMatteSelection() },
            set: { selection in
                let mode = currentState().matteMode
                viewModel.setClipMatte(clipID: inspector.clipID, mode: mode, selection: selection)
            }
        )
    }

    private func currentMatteSelection() -> MatteSourceSelection {
        let state = currentState()
        if state.useLayerAbove { return .layerAbove }
        if let clipID = state.matteSourceClipID { return .clip(clipID) }
        return .none
    }

    private func currentState() -> ClipInspectorState {
        viewModel.inspectorState ?? inspector
    }
}

private struct InspectorNumberRow: View {
    let title: String
    let value: Binding<Double>
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 60)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorSliderRow: View {
    let title: String
    let value: Binding<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
