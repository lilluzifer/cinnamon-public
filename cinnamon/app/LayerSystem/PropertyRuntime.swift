import Foundation
import simd

public final class LayerPropertyStore: PropertyStore {
    public private(set) var layers: [UUID: MediaLayer]

    public init(layers: [MediaLayer] = []) {
        self.layers = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
    }

    public func getValue(layer: MediaLayer, path: String, mediaSize: SIMD2<Float>) -> Float {
        switch path {
        case "transform.position.x": return layer.transform.position.x
        case "transform.position.y": return layer.transform.position.y
        case "transform.scale.x": return Units.fromEngine(layer.transform.scale.x, unit: "%")
        case "transform.scale.y": return Units.fromEngine(layer.transform.scale.y, unit: "%")
        case "transform.rotation": return Units.fromEngine(layer.transform.rotation, unit: "°")
        case "transform.opacity": return Units.fromEngine(layer.transform.opacity, unit: "%")
        case "transform.anchor.x": return Units.fromEngine(layer.transform.anchor.x, unit: "%")
        case "transform.anchor.y": return Units.fromEngine(layer.transform.anchor.y, unit: "%")
        default: return 0
        }
    }

    public func setValue(_ value: Float, for path: String, on layerID: UUID, mediaSize: SIMD2<Float>) {
        guard var layer = layers[layerID] else { return }
        switch path {
        case "transform.position.x": layer.transform.position.x = value
        case "transform.position.y": layer.transform.position.y = value
        case "transform.scale.x": layer.transform.scale.x = Units.toEngine(value, unit: "%")
        case "transform.scale.y": layer.transform.scale.y = Units.toEngine(value, unit: "%")
        case "transform.rotation": layer.transform.rotation = Units.toEngine(value, unit: "°")
        case "transform.opacity": layer.transform.opacity = clamp01(Units.toEngine(value, unit: "%"))
        case "transform.anchor.x": layer.transform.anchor.x = Units.toEngine(value, unit: "%")
        case "transform.anchor.y": layer.transform.anchor.y = Units.toEngine(value, unit: "%")
        default: break
        }
        layers[layerID] = layer
    }

    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
