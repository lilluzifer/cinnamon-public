import AVFoundation
import CoreVideo

protocol FrameProvider {
    func open(asset: AVAsset) throws
    func frame(at mediaTime: CMTime, exact: Bool) -> CVPixelBuffer?
    func close()
}

final class PlayerFrameProvider: FrameProvider {
    func open(asset: AVAsset) throws {
        // Placeholder
    }

    func frame(at mediaTime: CMTime, exact: Bool) -> CVPixelBuffer? {
        nil
    }

    func close() {}
}

final class ReaderFrameProvider: FrameProvider {
    func open(asset: AVAsset) throws {
        // Placeholder
    }

    func frame(at mediaTime: CMTime, exact: Bool) -> CVPixelBuffer? {
        nil
    }

    func close() {}
}
