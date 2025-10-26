import Foundation

public enum BlendMode: UInt32, CaseIterable, Codable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight
    case hardLight
    case colorDodge
    case colorBurn
    case darken
    case lighten
    case difference
    case exclusion
}
