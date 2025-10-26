import Foundation

public enum LayerTransformValidation {
    public static func validate(layers: [MediaLayer], compositionSize: SIMD2<Float>) -> [String] {
        var errors: [String] = []
        for layer in layers {
            if layer.transform.opacity < 0 || layer.transform.opacity > 1 {
                errors.append("Layer \(layer.name) has invalid opacity \(layer.transform.opacity)")
            }
            if layer.transform.scale.x.isNaN || layer.transform.scale.y.isNaN {
                errors.append("Layer \(layer.name) has NaN scale")
            }
            if abs(layer.transform.rotation) > Float.pi * 2 * 100 {
                errors.append("Layer \(layer.name) rotation out of bounds")
            }
            if layer.transform.position.x < -compositionSize.x * 5 || layer.transform.position.x > compositionSize.x * 5 {
                errors.append("Layer \(layer.name) position exceeds guardrails")
            }
        }
        return errors
    }
}
