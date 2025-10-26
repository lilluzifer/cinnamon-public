import Foundation
import SwiftUI

public struct PropertyLane: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let propertyPath: String
    public let valueRange: ClosedRange<Float>
    public let unit: String
    public let colorTagHex: String
    public let defaultValue: Float

    public init(id: UUID = UUID(),
                name: String,
                propertyPath: String,
                valueRange: ClosedRange<Float>,
                unit: String,
                colorTag: Color,
                defaultValue: Float) {
        self.id = id
        self.name = name
        self.propertyPath = propertyPath
        self.valueRange = valueRange
        self.unit = unit
        self.colorTagHex = colorTag.toHexString()
        self.defaultValue = defaultValue
    }

    public var colorTag: Color { Color(hex: colorTagHex) }
}

public enum PropertyRegistry {
    public static let standard: [PropertyLane] = [
        .init(name: "Position X", propertyPath: "transform.position.x", valueRange: -2000...2000, unit: "px", colorTag: .red, defaultValue: 0),
        .init(name: "Position Y", propertyPath: "transform.position.y", valueRange: -2000...2000, unit: "px", colorTag: .green, defaultValue: 0),
        .init(name: "Scale X", propertyPath: "transform.scale.x", valueRange: 0...500, unit: "%", colorTag: .blue, defaultValue: 100),
        .init(name: "Scale Y", propertyPath: "transform.scale.y", valueRange: 0...500, unit: "%", colorTag: .cyan, defaultValue: 100),
        .init(name: "Rotation", propertyPath: "transform.rotation", valueRange: -360...360, unit: "°", colorTag: .purple, defaultValue: 0),
        .init(name: "Opacity", propertyPath: "transform.opacity", valueRange: 0...100, unit: "%", colorTag: .orange, defaultValue: 100),
        .init(name: "Anchor X", propertyPath: "transform.anchor.x", valueRange: 0...100, unit: "%", colorTag: .yellow, defaultValue: 50),
        .init(name: "Anchor Y", propertyPath: "transform.anchor.y", valueRange: 0...100, unit: "%", colorTag: .pink, defaultValue: 50),
    ]
}

public protocol PropertyStore {
    func getValue(layer: MediaLayer, path: String, mediaSize: SIMD2<Float>) -> Float
    mutating func setValue(_ value: Float, for path: String, on layerID: UUID, mediaSize: SIMD2<Float>)
}

public enum Units {
    public static func toEngine(_ value: Float, unit: String) -> Float {
        switch unit {
        case "%": return value * 0.01
        case "°": return value * .pi / 180
        default: return value
        }
    }

    public static func fromEngine(_ value: Float, unit: String) -> Float {
        switch unit {
        case "%": return value * 100
        case "°": return value * 180 / .pi
        default: return value
        }
    }
}

private extension Color {
    #if canImport(AppKit)
    func toHexString() -> String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    init(hex: String) {
        var formatted = hex
        if formatted.hasPrefix("#") { formatted.removeFirst() }
        guard formatted.count == 6,
              let value = Int(formatted, radix: 16) else {
            self = .gray
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
    #else
    func toHexString() -> String { "#808080" }
    init(hex: String) { self = .gray }
    #endif
}
