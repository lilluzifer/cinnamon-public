import SwiftUI
import MetalKit

/// SwiftUI wrapper that embeds the MTKView from MetalRenderer.
struct PlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: WorkspaceViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return offlineFallbackView()
        }

        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = ProjectSettings.optimalMTKViewFrameRate(for: viewModel.currentCompositionFrameRate)
        mtkView.clearColor = MTLClearColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1.0)

        if let renderer = MetalRenderer(mtkView: mtkView) {
            context.coordinator.renderer = renderer
        } else {
            return offlineFallbackView()
        }

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.isPaused = false

        // Update frame rate to constant 60fps for smooth UI
        nsView.preferredFramesPerSecond = ProjectSettings.optimalMTKViewFrameRate(for: viewModel.currentCompositionFrameRate)

        // Note: MetalRenderer updates are handled separately to avoid update loops
    }

    /// Coordinator keeps a strong reference to the renderer for the lifetime of the MTKView.
    final class Coordinator {
        var renderer: MetalRenderer?

        init() {}
    }

    private func offlineFallbackView() -> MTKView {
        let fallback = MTKView()
        fallback.isPaused = true
        fallback.enableSetNeedsDisplay = false
        fallback.clearColor = MTLClearColor(red: 0.2, green: 0.1, blue: 0.1, alpha: 1.0)
        return fallback
    }
}
