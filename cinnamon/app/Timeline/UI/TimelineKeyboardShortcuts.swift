import SwiftUI
import AppKit

struct TimelineKeyboardShortcutHandler: ViewModifier {
    @ObservedObject var controller: TimelineController
    let bringForward: () -> Void
    let sendBackward: () -> Void
    let bringToFront: () -> Void
    let sendToBack: () -> Void

    func body(content: Content) -> some View {
        content
            .background(Representable(controller: controller,
                                      bringForward: bringForward,
                                      sendBackward: sendBackward,
                                      bringToFront: bringToFront,
                                      sendToBack: sendToBack))
    }

    private struct Representable: NSViewRepresentable {
        let controller: TimelineController
        let bringForward: () -> Void
        let sendBackward: () -> Void
        let bringToFront: () -> Void
        let sendToBack: () -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handle(event: event)
                return event
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        private func handle(event: NSEvent) {
            guard let characters = event.charactersIgnoringModifiers else { return }
            switch characters.lowercased() {
            case " ":
                // CRITICAL FIX: Access TransportController state DIRECTLY (not via Combine)
                // Accessing controller.transportState has 1-2 frame delay due to async Combine propagation
                // This causes race conditions when user presses spacebar quickly
                // Direct access ensures we get the ACTUAL current state
                let transport = TransportController.shared
                let currentState = transport.playbackState

                if currentState == .playing {
                    controller.requestPause()
                } else {
                    // Paused or scrubbing → start playback
                    controller.requestPlay(rate: 1.0, completion: nil)
                }
            case "j": controller.stepBackward()
            case "k": controller.stepForward()
            case "b":
                controller.setWorkIn(at: controller.playheadTime)
            case "n":
                controller.setWorkOut(at: controller.playheadTime)
            case "x":
                if event.modifierFlags.contains(.option) {
                    controller.clearWorkArea()
                }
            case "]":
                if event.modifierFlags.contains(.command) {
                    if event.modifierFlags.contains(.option) {
                        bringToFront()
                    } else {
                        bringForward()
                    }
                }
            case "[":
                if event.modifierFlags.contains(.command) {
                    if event.modifierFlags.contains(.option) {
                        sendToBack()
                    } else {
                        sendBackward()
                    }
                }
            default: break
            }
        }
    }
}

extension View {
    func timelineKeyboardShortcuts(controller: TimelineController,
                                   bringForward: @escaping () -> Void = {},
                                   sendBackward: @escaping () -> Void = {},
                                   bringToFront: @escaping () -> Void = {},
                                   sendToBack: @escaping () -> Void = {}) -> some View {
        modifier(TimelineKeyboardShortcutHandler(controller: controller,
                                                 bringForward: bringForward,
                                                 sendBackward: sendBackward,
                                                 bringToFront: bringToFront,
                                                 sendToBack: sendToBack))
    }
}
