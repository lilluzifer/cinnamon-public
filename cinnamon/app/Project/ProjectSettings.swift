import Foundation
import SwiftUI
import Combine

/// Project-wide settings that affect timeline behavior and rendering
@MainActor
final class ProjectSettings: ObservableObject {

    enum FrameRate: Double, CaseIterable, CustomStringConvertible {
        case fps23_976 = 23.976
        case fps24 = 24.0
        case fps25 = 25.0
        case fps29_97 = 29.97
        case fps30 = 30.0
        case fps50 = 50.0
        case fps59_94 = 59.94
        case fps60 = 60.0

        var description: String {
            switch self {
            case .fps23_976: return "23.976 fps (Cinema)"
            case .fps24: return "24 fps (Cinema)"
            case .fps25: return "25 fps (PAL)"
            case .fps29_97: return "29.97 fps (NTSC)"
            case .fps30: return "30 fps"
            case .fps50: return "50 fps (PAL High)"
            case .fps59_94: return "59.94 fps (NTSC High)"
            case .fps60: return "60 fps"
            }
        }

        var frameDuration: TimeInterval {
            return 1.0 / rawValue
        }
    }

    static let shared = ProjectSettings()

    @Published var frameRate: FrameRate = .fps24 {
        didSet {
            NotificationCenter.default.post(name: .projectFrameRateChanged, object: frameRate)
        }
    }

    @Published var resolution: CGSize = CGSize(width: 1920, height: 1080)

    private init() {}

    var frameDuration: TimeInterval {
        frameRate.frameDuration
    }

    var preferredMTKViewFrameRate: Int {
        // For smooth playback, MTKView should run at display rate or higher
        let displayRate = Int(frameRate.rawValue)
        // Ensure we have at least 60fps for smooth UI, but respect high frame rates
        return max(60, displayRate)
    }

    /// MTKView runs at display refresh rate (60fps) for smooth UI
    /// Timeline ticks at composition framerate, video decodes at native framerate
    /// Renderer picks best frame for current timeline time (After Effects behavior)
    static func optimalMTKViewFrameRate(for compositionFrameRate: Double) -> Int {
        // Always 60fps for smooth UI, independent of composition framerate
        return 60
    }
}

extension Notification.Name {
    static let projectFrameRateChanged = Notification.Name("ProjectFrameRateChanged")
    static let compositionFrameRateChanged = Notification.Name("CompositionFrameRateChanged")
    // DEPRECATED: frameUpdatedDuringScrub - Removed in favor of After Effects-style per-clip caching
    // VideoFramePool now manages cache with timestamp tracking, no global notifications needed
}