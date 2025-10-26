import Foundation
import AppKit
import Combine

public enum TrimDirection: Sendable { case `in`, out }

public enum TimelineGestureType: Equatable, Sendable {
    case moveLayer(UUID)
    case trimLayer(UUID, TrimDirection)
    case slipLayer(UUID)
    case slideLayer(UUID)
    case blade
    case boxSelect
    case scrubTimeline
    case moveKeyframe(UUID)
}

extension TimelineGestureType {
    var cursor: NSCursor {
        switch self {
        case .moveLayer:
            return .closedHand
        case .trimLayer(_, let direction):
            return direction == .in ? .resizeLeft : .resizeRight
        case .slipLayer:
            return .resizeLeftRight
        case .slideLayer:
            return .openHand
        case .blade:
            return NSCursor.crosshair
        case .boxSelect:
            return NSCursor.pointingHand
        case .scrubTimeline:
            return NSCursor.resizeLeftRight
        case .moveKeyframe:
            return NSCursor.arrow
        }
    }
}

public final class TimelineGestureRecognizer: ObservableObject {
    @Published public private(set) var activeGesture: TimelineGestureType?

    public init() {}

    public func begin(_ gesture: TimelineGestureType) {
        activeGesture = gesture
        gesture.cursor.set()
    }

    public func end() {
        activeGesture = nil
        NSCursor.arrow.set()
    }
}
