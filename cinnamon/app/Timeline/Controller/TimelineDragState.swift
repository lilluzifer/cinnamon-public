import Foundation
import CoreGraphics
import Combine
import AppKit

// MARK: - Drag State Machine

public enum DragMode: Equatable, Sendable {
    case undecided
    case move(clipID: UUID)
    case trimIn(clipID: UUID)
    case trimOut(clipID: UUID)
    case reorder(layerID: UUID)
    case scrub
    case none
}

public struct DragAnchor: Sendable {
    let startPoint: CGPoint
    let startTime: TimeInterval
    let clipStartTime: TimeInterval?
    let viewportStart: TimeInterval
    let viewportDuration: TimeInterval

    init(point: CGPoint, time: TimeInterval, clipStart: TimeInterval? = nil, viewportStart: TimeInterval, viewportDuration: TimeInterval) {
        self.startPoint = point
        self.startTime = time
        self.clipStartTime = clipStart
        self.viewportStart = viewportStart
        self.viewportDuration = viewportDuration
    }
}

public final class TimelineDragState: ObservableObject {
    @Published public private(set) var mode: DragMode = .none
    @Published public private(set) var isDragging: Bool = false
    @Published public private(set) var currentPoint: CGPoint = .zero
    @Published public private(set) var deltaX: CGFloat = 0
    @Published public private(set) var deltaY: CGFloat = 0
    @Published public private(set) var isTransportFrozen: Bool = false

    private var anchor: DragAnchor?
    private var accumDelta: CGSize = .zero
    private let directionLockThreshold: CGFloat = 5.0
    private let edgeHitZone: CGFloat = 8.0
    private let reorderGrabZone: CGFloat = 24.0
    private weak var transportController: TransportController?

    public init() {}

    func setTransportController(_ controller: TransportController) {
        self.transportController = controller
    }

    private func freezeTransport() {
        guard !isTransportFrozen else { return }
        isTransportFrozen = true
        transportController?.pauseForDrag()
        print("[DragState] Transport FROZEN for reorder")
    }

    private func unfreezeTransport() {
        guard isTransportFrozen else { return }
        isTransportFrozen = false
        transportController?.resumeAfterDrag()
        print("[DragState] Transport UNFROZEN")
    }

    // MARK: - Hit Testing

    public func hitTest(at point: CGPoint, in rect: CGRect, hasReorderHandle: Bool = false) -> HitZone {
        // Check reorder grab zone FIRST (dedicated 24px area on left)
        // This prevents overlap with trim zones
        if hasReorderHandle {
            // Reorder handle is a separate 24px zone on the left
            let reorderRect = CGRect(x: rect.minX - reorderGrabZone,
                                     y: rect.minY,
                                     width: reorderGrabZone,
                                     height: rect.height)
            if reorderRect.contains(point) {
                return .reorderHandle
            }
        }

        // Check edge zones for trimming (8px each side)
        if point.x < rect.minX + edgeHitZone {
            return .trimIn
        }
        if point.x > rect.maxX - edgeHitZone {
            return .trimOut
        }

        // Body zone for move
        return .body
    }

    // MARK: - Drag Lifecycle

    public func beginDrag(at point: CGPoint,
                         hitZone: HitZone,
                         clipID: UUID? = nil,
                         layerID: UUID? = nil,
                         time: TimeInterval,
                         clipStart: TimeInterval? = nil,
                         viewportStart: TimeInterval,
                         viewportDuration: TimeInterval) {
        guard !isDragging else { return }

        currentPoint = point
        anchor = DragAnchor(point: point, time: time, clipStart: clipStart,
                           viewportStart: viewportStart, viewportDuration: viewportDuration)
        accumDelta = .zero
        deltaX = 0
        deltaY = 0

        // Set initial mode based on hit zone
        switch hitZone {
        case .reorderHandle:
            if let layerID = layerID {
                mode = .reorder(layerID: layerID)
            } else {
                mode = .undecided
            }
        case .trimIn:
            if let clipID = clipID {
                mode = .undecided // Will lock to trimIn after direction lock
            } else {
                mode = .none
            }
        case .trimOut:
            if let clipID = clipID {
                mode = .undecided // Will lock to trimOut after direction lock
            } else {
                mode = .none
            }
        case .body:
            if let clipID = clipID {
                mode = .undecided // Will lock to move after direction lock
            } else {
                mode = .scrub
            }
        }

        isDragging = true

        // Freeze transport for reorder operations
        if case .reorder = mode {
            freezeTransport()
        }
    }

    public func updateDrag(to point: CGPoint, clipID: UUID? = nil, hitZone: HitZone) {
        guard isDragging, let anchor = anchor else { return }

        currentPoint = point
        let totalDelta = CGSize(width: point.x - anchor.startPoint.x,
                                height: point.y - anchor.startPoint.y)

        // Apply direction lock if still undecided
        if mode == .undecided {
            let absX = abs(totalDelta.width)
            let absY = abs(totalDelta.height)

            if absX > directionLockThreshold || absY > directionLockThreshold {
                // Lock direction based on dominant axis
                if absX >= absY {
                    // Horizontal drag - determine edit mode
                    switch hitZone {
                    case .trimIn:
                        if let clipID = clipID {
                            mode = .trimIn(clipID: clipID)
                        }
                    case .trimOut:
                        if let clipID = clipID {
                            mode = .trimOut(clipID: clipID)
                        }
                    case .body:
                        if let clipID = clipID {
                            mode = .move(clipID: clipID)
                        }
                    case .reorderHandle:
                        // Stay in reorder if started there
                        break
                    }
                } else {
                    // Vertical drag - check for reorder
                    if hitZone == .reorderHandle, let clipID = clipID {
                        // Find the layer ID for this clip
                        mode = .reorder(layerID: clipID) // Using clipID as placeholder
                    } else if case .reorder = mode {
                        // Already in reorder, keep it
                    } else {
                        // Cancel other modes for vertical drag
                        mode = .none
                    }
                }
            }
        }

        // Calculate frame-aligned deltas
        deltaX = totalDelta.width
        deltaY = totalDelta.height
        accumDelta = totalDelta
    }

    public func endDrag() -> (mode: DragMode, deltaX: CGFloat, deltaY: CGFloat, anchor: DragAnchor?) {
        let result = (mode: mode, deltaX: deltaX, deltaY: deltaY, anchor: anchor)

        // Unfreeze transport if it was frozen
        if isTransportFrozen {
            unfreezeTransport()
        }

        // Reset state
        mode = .none
        isDragging = false
        currentPoint = .zero
        deltaX = 0
        deltaY = 0
        anchor = nil
        accumDelta = .zero

        return result
    }

    public func cancelDrag() {
        mode = .none
        isDragging = false
        currentPoint = .zero
        deltaX = 0
        deltaY = 0
        anchor = nil
        accumDelta = .zero
    }

    // MARK: - Time Calculation

    public func timeForCurrentPosition(viewportStart: TimeInterval, viewportDuration: TimeInterval, totalWidth: CGFloat) -> TimeInterval {
        guard totalWidth > 0 && viewportDuration > 0 else { return viewportStart }

        // Calculate time using absolute position
        let normalizedX = currentPoint.x / totalWidth
        let timeOffset = normalizedX * viewportDuration
        return viewportStart + timeOffset
    }

    public func timeDelta(pixelsPerFrame: CGFloat, frameDuration: TimeInterval) -> TimeInterval {
        guard pixelsPerFrame > 0 else { return 0 }

        // Convert pixel delta to time delta
        let frames = round(deltaX / pixelsPerFrame)
        return frames * frameDuration
    }
}

// MARK: - Hit Zone

public enum HitZone: Equatable, Sendable {
    case body
    case trimIn
    case trimOut
    case reorderHandle
}

// MARK: - Cursor Management

extension DragMode {
    public var cursor: NSCursor {
        switch self {
        case .undecided, .none:
            return .arrow
        case .move:
            return .closedHand
        case .trimIn:
            return .resizeLeft
        case .trimOut:
            return .resizeRight
        case .reorder:
            return .resizeUpDown
        case .scrub:
            return .resizeLeftRight
        }
    }
}