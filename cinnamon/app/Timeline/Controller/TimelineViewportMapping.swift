import Foundation
import CoreGraphics

// MARK: - Enhanced Viewport with Stable Time Mapping

public struct TimelineViewportMapping {
    private let visibleStart: TimeInterval
    private let visibleDuration: TimeInterval
    private let totalWidth: CGFloat
    private let frameDuration: TimeInterval
    private let frameRate: Double

    // Cached calculations
    private let pixelsPerSecond: CGFloat
    private let pixelsPerFrame: CGFloat
    private let secondsPerPixel: TimeInterval

    public init(visibleStart: TimeInterval, visibleDuration: TimeInterval, totalWidth: CGFloat, frameDuration: TimeInterval, frameRate: Double) {
        self.visibleStart = visibleStart
        self.visibleDuration = visibleDuration
        self.totalWidth = totalWidth
        self.frameDuration = frameDuration
        self.frameRate = frameRate

        // Pre-calculate conversions
        if totalWidth > 0 && visibleDuration > 0 {
            self.pixelsPerSecond = totalWidth / visibleDuration
            self.pixelsPerFrame = pixelsPerSecond / frameRate
            self.secondsPerPixel = visibleDuration / totalWidth
        } else {
            self.pixelsPerSecond = 0
            self.pixelsPerFrame = 0
            self.secondsPerPixel = 0
        }
    }

    // MARK: - Stable Time Mapping (Absolute)

    /// Convert X position to timeline time (absolute, not relative to viewport)
    public func timeForX(_ x: CGFloat) -> TimeInterval {
        guard totalWidth > 0 else { return visibleStart }

        // Calculate time using absolute mapping
        let normalizedX = x / totalWidth
        let timeOffset = normalizedX * visibleDuration
        return visibleStart + timeOffset
    }

    /// Convert timeline time to X position (absolute)
    public func xForTime(_ time: TimeInterval) -> CGFloat {
        guard visibleDuration > 0 else { return 0 }

        // Calculate position using absolute mapping
        let timeOffset = time - visibleStart
        let normalizedOffset = timeOffset / visibleDuration
        return normalizedOffset * totalWidth
    }

    // MARK: - Frame-Aligned Operations

    /// Convert X delta to time delta with optional frame quantization
    public func timeDeltaForPixelDelta(_ pixelDelta: CGFloat, quantizeToFrames: Bool = false) -> TimeInterval {
        guard totalWidth > 0 else { return 0 }

        let timeDelta = pixelDelta * secondsPerPixel

        if quantizeToFrames && frameDuration > 0 {
            // Quantize to nearest frame
            let frames = round(timeDelta / frameDuration)
            return frames * frameDuration
        }

        return timeDelta
    }

    /// Convert time delta to pixel delta
    public func pixelDeltaForTimeDelta(_ timeDelta: TimeInterval) -> CGFloat {
        return timeDelta * pixelsPerSecond
    }

    // MARK: - Clip Placement

    /// Calculate exact clip position after drag
    public func finalClipPosition(dragStartTime: TimeInterval,
                                  dragStartX: CGFloat,
                                  currentX: CGFloat,
                                  snapEngine: SnapEngine? = nil,
                                  quantizeToFrames: Bool = true) -> TimeInterval {
        // Calculate absolute time at current position
        let currentTime = timeForX(currentX)

        // Apply snapping if enabled
        var finalTime = currentTime
        if let snapEngine = snapEngine, snapEngine.isActive {
            finalTime = snapEngine.snapTime(currentTime)
        } else if quantizeToFrames && frameDuration > 0 {
            // Frame quantization without snapping
            let frameIndex = round(finalTime / frameDuration)
            finalTime = frameIndex * frameDuration
        }

        return max(0, finalTime)
    }

    /// Calculate trim position with source offset
    public func trimPosition(edge: TrimEdge,
                            originalTime: TimeInterval,
                            dragDeltaX: CGFloat,
                            minDuration: TimeInterval = 0.01,
                            maxTime: TimeInterval? = nil) -> (dstTime: TimeInterval, srcDelta: TimeInterval) {
        let timeDelta = timeDeltaForPixelDelta(dragDeltaX, quantizeToFrames: true)

        var newTime = originalTime + timeDelta

        // Apply constraints
        if let maxTime = maxTime {
            newTime = min(newTime, maxTime)
        }
        newTime = max(0, newTime)

        // Calculate source offset (assuming speed = 1.0 for now)
        let srcDelta = timeDelta

        return (newTime, srcDelta)
    }

    // MARK: - Reorder Operations

    /// Calculate track index from Y position
    public func trackIndexForY(_ y: CGFloat, trackHeight: CGFloat, trackSpacing: CGFloat) -> Int {
        guard trackHeight > 0 else { return 0 }

        let effectiveHeight = trackHeight + trackSpacing
        let index = Int(floor(y / effectiveHeight))
        return max(0, index)
    }

    /// Calculate Y position for track index
    public func yForTrackIndex(_ index: Int, trackHeight: CGFloat, trackSpacing: CGFloat) -> CGFloat {
        let effectiveHeight = trackHeight + trackSpacing
        return CGFloat(index) * effectiveHeight
    }

    // MARK: - Debug Info

    public var debugInfo: String {
        """
        Viewport Mapping:
        - Width: \(String(format: "%.1f", totalWidth))px
        - Duration: \(String(format: "%.3f", visibleDuration))s
        - Start: \(String(format: "%.3f", visibleStart))s
        - PPF: \(String(format: "%.2f", pixelsPerFrame))
        - PPS: \(String(format: "%.2f", pixelsPerSecond))
        """
    }
}

// MARK: - Supporting Types

public enum TrimEdge {
    case `in`
    case out
}

// MARK: - Drag Anchor with Mapping

public struct MappedDragAnchor {
    let startPoint: CGPoint
    let startTime: TimeInterval
    let clipStartTime: TimeInterval
    let viewportStart: TimeInterval
    let viewportDuration: TimeInterval
    let totalWidth: CGFloat
    let frameDuration: TimeInterval
    let frameRate: Double

    public init(point: CGPoint, clipTime: TimeInterval, viewportStart: TimeInterval, viewportDuration: TimeInterval, width: CGFloat, frameDuration: TimeInterval, frameRate: Double) {
        self.startPoint = point
        self.clipStartTime = clipTime
        self.viewportStart = viewportStart
        self.viewportDuration = viewportDuration
        self.totalWidth = width
        self.frameDuration = frameDuration
        self.frameRate = frameRate

        // Calculate start time from initial point
        if width > 0 && viewportDuration > 0 {
            let normalizedX = point.x / width
            let timeOffset = normalizedX * viewportDuration
            self.startTime = viewportStart + timeOffset
        } else {
            self.startTime = viewportStart
        }
    }

    /// Calculate final position using absolute mapping
    public func finalPosition(currentX: CGFloat, snapEngine: SnapEngine? = nil) -> TimeInterval {
        guard totalWidth > 0 && viewportDuration > 0 else { return startTime }

        // Calculate absolute time at current position
        let normalizedX = currentX / totalWidth
        let timeOffset = normalizedX * viewportDuration
        var finalTime = viewportStart + timeOffset

        // Apply snapping if enabled
        if let snapEngine = snapEngine, snapEngine.isActive {
            finalTime = snapEngine.snapTime(finalTime)
        } else if frameDuration > 0 {
            // Frame quantization without snapping
            let frameIndex = round(finalTime / frameDuration)
            finalTime = frameIndex * frameDuration
        }

        return max(0, finalTime)
    }

    /// Calculate time delta from start
    public func timeDelta(currentX: CGFloat) -> TimeInterval {
        guard totalWidth > 0 && viewportDuration > 0 else { return 0 }

        let normalizedX = currentX / totalWidth
        let timeOffset = normalizedX * viewportDuration
        let currentTime = viewportStart + timeOffset
        return currentTime - startTime
    }
}