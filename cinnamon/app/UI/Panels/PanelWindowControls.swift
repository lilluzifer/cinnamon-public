import SwiftUI

struct PanelWindowControls: View {
    let panel: PanelFocus
    @ObservedObject var viewModel: WorkspaceViewModel

    var body: some View {
        HStack(spacing: 4) {
            Button(action: {}) {
                Image(systemName: "minus")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(WindowControlButtonStyle())

            Button(action: {}) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(WindowControlButtonStyle())

            Button(action: {}) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(WindowControlButtonStyle())
        }
    }
}

private struct WindowControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(configuration.isPressed ?
                        Color.black.opacity(0.2) :
                        Color.black.opacity(0.1))
            )
    }
}