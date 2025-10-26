import Foundation
import simd

public struct MediaLayer: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var mediaSize: SIMD2<Float>
    public var transform: Transform2D
    public var enabled: Bool
    public var blendMode: BlendMode

    public init(id: UUID = UUID(),
                name: String,
                mediaSize: SIMD2<Float>,
                transform: Transform2D,
                enabled: Bool = true,
                blendMode: BlendMode = .normal) {
        self.id = id
        self.name = name
        self.mediaSize = mediaSize
        self.transform = transform
        self.enabled = enabled
        self.blendMode = blendMode
    }
}
