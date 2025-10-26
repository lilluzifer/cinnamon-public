import Foundation

public struct EditMode: Equatable, Sendable {
    public enum Kind: Sendable { case trimIn, trimOut, move, slip, slide, roll }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

public struct RippleEditMode: Equatable, Sendable {
    public enum Kind: Sendable { case insert, delete }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

public enum TimelineMode: Equatable, Sendable {
    case idle, playback, scrub
    case edit(EditMode)
    case rippleEdit(RippleEditMode)
    case boxSelect
}

public struct TimelineStateMachine: Sendable {
    public private(set) var mode: TimelineMode

    public init(mode: TimelineMode = .idle) {
        self.mode = mode
    }

    public mutating func transition(to newMode: TimelineMode) {
        mode = newMode
    }
}
