import Foundation
import SwiftUI
import Combine

public enum KeyframeInterpolationType: String, CaseIterable, Codable, Sendable {
    case linear, bezier, easeIn, easeOut, easeInOut, hold, bounce, elastic
}

public final class EnhancedKeyframe: ObservableObject, Codable, Identifiable {
    public let id: UUID
    @Published public var time: TimeInterval
    @Published public var value: Float
    @Published public var interpolationType: KeyframeInterpolationType
    @Published public var inTangent: CGPoint
    @Published public var outTangent: CGPoint

    public init(id: UUID = UUID(),
                time: TimeInterval,
                value: Float,
                interpolationType: KeyframeInterpolationType,
                inTangent: CGPoint = .zero,
                outTangent: CGPoint = .zero) {
        self.id = id
        self.time = time
        self.value = value
        self.interpolationType = interpolationType
        self.inTangent = inTangent
        self.outTangent = outTangent
    }

    enum CodingKeys: String, CodingKey { case id, time, value, interpolationType, inTangentX, inTangentY, outTangentX, outTangentY }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(TimeInterval.self, forKey: .time)
        value = try container.decode(Float.self, forKey: .value)
        interpolationType = try container.decode(KeyframeInterpolationType.self, forKey: .interpolationType)
        let inX = try container.decode(CGFloat.self, forKey: .inTangentX)
        let inY = try container.decode(CGFloat.self, forKey: .inTangentY)
        inTangent = CGPoint(x: inX, y: inY)
        let outX = try container.decode(CGFloat.self, forKey: .outTangentX)
        let outY = try container.decode(CGFloat.self, forKey: .outTangentY)
        outTangent = CGPoint(x: outX, y: outY)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(value, forKey: .value)
        try container.encode(interpolationType, forKey: .interpolationType)
        try container.encode(inTangent.x, forKey: .inTangentX)
        try container.encode(inTangent.y, forKey: .inTangentY)
        try container.encode(outTangent.x, forKey: .outTangentX)
        try container.encode(outTangent.y, forKey: .outTangentY)
    }
}

public final class EnhancedKeyframeTrack: ObservableObject {
    public let layerID: UUID
    public let propertyLane: PropertyLane
    @Published public var keyframes: [EnhancedKeyframe] = []
    @Published public var isVisible: Bool = true
    @Published public var height: CGFloat = 60

    public init(layerID: UUID, lane: PropertyLane) {
        self.layerID = layerID
        self.propertyLane = lane
    }

    public func value(at time: TimeInterval) -> Float {
        guard let first = keyframes.first else { return propertyLane.defaultValue }
        guard let last = keyframes.last else { return first.value }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        let pairs = zip(keyframes, keyframes.dropFirst())
        for (a, b) in pairs where time >= a.time && time <= b.time {
            let t = Float((time - a.time) / max(b.time - a.time, 0.0001))
            return interpolate(from: a, to: b, t: t)
        }
        return last.value
    }

    private func interpolate(from a: EnhancedKeyframe, to b: EnhancedKeyframe, t: Float) -> Float {
        switch a.interpolationType {
        case .linear:
            return a.value + (b.value - a.value) * t
        case .hold:
            return a.value
        default:
            return a.value + (b.value - a.value) * t // Placeholder for bezier/ease.
        }
    }
}
