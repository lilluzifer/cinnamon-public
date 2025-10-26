import Foundation

public struct LayerTransformTelemetry: Sendable {
    public var averageOpacity: Float
    public var maxRotationDegrees: Float
    public var averageScale: SIMD2<Float>

    public init(layers: [MediaLayer]) {
        let opacities = layers.map { $0.transform.opacity }
        averageOpacity = Float(opacities.reduce(0, +) / max(1, Float(opacities.count)))
        let rotations = layers.map { $0.transform.rotation }
        maxRotationDegrees = rotations.map { Units.fromEngine($0, unit: "°") }.max() ?? 0
        let scales = layers.map { $0.transform.scale }
        if scales.isEmpty {
            averageScale = .zero
        } else {
            let sum = scales.reduce(.zero) { acc, next in acc + next }
            averageScale = sum / Float(scales.count)
        }
    }
}
