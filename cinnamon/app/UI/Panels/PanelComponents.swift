import SwiftUI

struct PanelHeader: View {
    let title: String
    let panel: PanelFocus
    @ObservedObject var viewModel: WorkspaceViewModel
    var trailing: AnyView = AnyView(EmptyView())

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(headerBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.focus(panel)
        }
    }

    private var headerBackground: some View {
        (viewModel.focusedPanel == panel ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.1))
            .overlay(Color.white.opacity(0.05))
    }
}

struct PanelContainer<Content: View>: View {
    let panel: PanelFocus
    @ObservedObject var viewModel: WorkspaceViewModel
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .opacity(0.85)
                .overlay(Color.black.opacity(0.05))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(borderColor, lineWidth: 1)
        )
        .onTapGesture {
            viewModel.focus(panel)
        }
    }

    private var borderColor: Color {
        viewModel.focusedPanel == panel ? Color.accentColor.opacity(0.6) : Color.black.opacity(0.15)
    }
}
