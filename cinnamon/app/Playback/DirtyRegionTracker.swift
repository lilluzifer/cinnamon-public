import Foundation
import CoreGraphics

/// Tracks dirty regions per Composition and calculates tile-aligned invalidation rects.
@MainActor
final class DirtyRegionTracker {

    struct DirtyUpdate {
        let compID: UUID
        let region: CGRect
        let reason: String
    }

    private struct CompositionState {
        var canvasSize: CGSize
        var layerBounds: [UUID: CGRect]
    }

    private var compositions: [UUID: CompositionState] = [:]

    func update(compID: UUID,
                canvasSize: CGSize,
                layers: [MediaLayer],
                reason: String) -> DirtyUpdate? {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        var state = compositions[compID] ?? CompositionState(canvasSize: canvasSize, layerBounds: [:])
        state.canvasSize = canvasSize

        var dirtyRegion = CGRect.null

        var nextBounds: [UUID: CGRect] = [:]
        nextBounds.reserveCapacity(layers.count)

        for layer in layers {
            let newBounds = DirtyRegionTracker.boundingRect(for: layer, canvasRect: canvasRect)
            let previous = state.layerBounds[layer.id]

            switch (previous, newBounds) {
            case let (old?, new?):
                if !old.equalTo(new) {
                    dirtyRegion = dirtyRegion.union(old).union(new)
                }
                nextBounds[layer.id] = new
            case (nil, let new?):
                dirtyRegion = dirtyRegion.union(new)
                nextBounds[layer.id] = new
            case (let old?, nil):
                dirtyRegion = dirtyRegion.union(old)
            case (nil, nil):
                break
            }
        }

        // Layers removed since last update
        let removed = state.layerBounds.keys.filter { id in
            layers.contains(where: { $0.id == id }) == false
        }
        for id in removed {
            if let old = state.layerBounds[id] {
                dirtyRegion = dirtyRegion.union(old)
            }
        }

        state.layerBounds = nextBounds
        compositions[compID] = state

        guard dirtyRegion.isNull == false, dirtyRegion.isInfinite == false else {
            return nil
        }

        let clamped = dirtyRegion.intersection(canvasRect)
        guard clamped.isNull == false else {
            return nil
        }

        return DirtyUpdate(compID: compID, region: clamped, reason: reason)
    }

    func invalidate(compID: UUID) {
        compositions.removeValue(forKey: compID)
    }

    func markAllDirty(compID: UUID, canvasSize: CGSize, reason: String) -> DirtyUpdate {
        let rect = CGRect(origin: .zero, size: canvasSize)
        compositions[compID] = CompositionState(canvasSize: canvasSize, layerBounds: [:])
        return DirtyUpdate(compID: compID, region: rect, reason: reason)
    }

    private static func boundingRect(for layer: MediaLayer, canvasRect: CGRect) -> CGRect? {
        guard layer.enabled, layer.transform.opacity > 0.01 else { return nil }

        let width = CGFloat(layer.mediaSize.x)
        let height = CGFloat(layer.mediaSize.y)
        guard width > 0, height > 0 else { return nil }

        let anchor = CGPoint(x: CGFloat(layer.transform.anchor.x) * width,
                             y: CGFloat(layer.transform.anchor.y) * height)
        let position = CGPoint(x: CGFloat(layer.transform.position.x),
                               y: CGFloat(layer.transform.position.y))

        let scale = CGAffineTransform(scaleX: CGFloat(layer.transform.scale.x),
                                      y: CGFloat(layer.transform.scale.y))
        let rotation = CGAffineTransform(rotationAngle: CGFloat(layer.transform.rotation))
        let translation = CGAffineTransform(translationX: position.x, y: position.y)
        let anchorTranslation = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)

        var transform = CGAffineTransform.identity
        transform = transform.concatenating(anchorTranslation)
        transform = transform.concatenating(scale)
        transform = transform.concatenating(rotation)
        transform = transform.concatenating(translation)

        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: 0, y: height)
        ].map { $0.applying(transform) }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in corners {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }

        let rect = CGRect(x: minX,
                          y: minY,
                          width: maxX - minX,
                          height: maxY - minY)

        guard rect.width > 0, rect.height > 0 else { return nil }

        let clipped = rect.intersection(canvasRect)
        return clipped.isNull ? nil : clipped
    }
}
