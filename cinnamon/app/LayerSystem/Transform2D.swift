import Foundation
import simd

public struct Transform2D: Codable, Equatable, Sendable {
    public var position: SIMD2<Float> = .zero
    public var scale: SIMD2<Float> = SIMD2<Float>(repeating: 1)
    public var rotation: Float = 0
    public var anchor: SIMD2<Float> = SIMD2<Float>(repeating: 0.5)
    public var opacity: Float = 1.0
    public var zIndex: Int = 0

    public init(position: SIMD2<Float> = .zero,
                scale: SIMD2<Float> = SIMD2<Float>(repeating: 1),
                rotation: Float = 0,
                anchor: SIMD2<Float> = SIMD2<Float>(repeating: 0.5),
                opacity: Float = 1.0,
                zIndex: Int = 0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.anchor = anchor
        self.opacity = opacity
        self.zIndex = zIndex
    }
}

public struct TransformUniforms: Sendable {
    public var modelToNDC: simd_float4x4
    public var opacity: Float
    public var blendModeIndex: UInt32
    public var _pad: SIMD2<Float> = .zero
}

public enum TransformMath {
    public static func modelToNDC(transform: Transform2D,
                                  mediaSize: SIMD2<Float>,
                                  canvasSize: SIMD2<Float>) -> simd_float4x4 {
        let anchorPixels = SIMD2<Float>(transform.anchor.x * mediaSize.x,
                                        transform.anchor.y * mediaSize.y)

        let anchorTranslation = float4x4(translationX: -anchorPixels.x,
                                         y: -anchorPixels.y,
                                         z: 0)

        let scaleMatrix = float4x4(scaleX: transform.scale.x,
                                   scaleY: transform.scale.y,
                                   scaleZ: 1)

        let rotationMatrix = float4x4(rotationZ: transform.rotation)

        let translation = float4x4(translationX: transform.position.x - canvasSize.x * 0.5,
                                   y: canvasSize.y * 0.5 - transform.position.y,
                                   z: 0)

        let ndc = float4x4(diagonal: SIMD4<Float>(2.0 / canvasSize.x,
                                                  -2.0 / canvasSize.y,
                                                  1,
                                                  1))

        return ndc * translation * rotationMatrix * scaleMatrix * anchorTranslation
    }
}

private extension float4x4 {
    init(translationX x: Float, y: Float, z: Float) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(x, y, z, 1)
    }

    init(scaleX x: Float, scaleY y: Float, scaleZ z: Float) {
        self = matrix_identity_float4x4
        columns.0.x = x
        columns.1.y = y
        columns.2.z = z
    }

    init(rotationZ angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        self = matrix_identity_float4x4
        columns.0.x = c
        columns.0.y = s
        columns.1.x = -s
        columns.1.y = c
    }
}
