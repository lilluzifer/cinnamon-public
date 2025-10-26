import Foundation
import simd

public struct SpaceMapping: Sendable {
    public var compSize: SIMD2<Float>
    public var viewSize: CGSize

    public init(compSize: SIMD2<Float>, viewSize: CGSize) {
        self.compSize = compSize
        self.viewSize = viewSize
    }

    public func compToView(_ comp: SIMD2<Float>) -> CGPoint {
        let x = CGFloat((comp.x / compSize.x) * Float(viewSize.width)) + viewSize.width * 0.5
        let y = viewSize.height * 0.5 - CGFloat((comp.y / compSize.y) * Float(viewSize.height))
        return CGPoint(x: x, y: y)
    }

    public func viewToComp(_ pt: CGPoint) -> SIMD2<Float> {
        let x = Float(pt.x - viewSize.width * 0.5) / Float(viewSize.width) * compSize.x
        let y = Float(viewSize.height * 0.5 - pt.y) / Float(viewSize.height) * compSize.y
        return SIMD2<Float>(x, y)
    }

    public func layerToComp(_ layerPt: SIMD2<Float>, mediaSize: SIMD2<Float>, t: Transform2D) -> SIMD2<Float> {
        let normalized = SIMD2<Float>(layerPt.x / mediaSize.x, layerPt.y / mediaSize.y)
        let transformed = normalized * t.scale
        return transformed + t.position
    }

    public func compToLayer(_ compPt: SIMD2<Float>, mediaSize: SIMD2<Float>, t: Transform2D) -> SIMD2<Float> {
        let relative = compPt - t.position
        let scaled = relative / t.scale
        return SIMD2<Float>(scaled.x * mediaSize.x, scaled.y * mediaSize.y)
    }
}
