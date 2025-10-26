import Foundation
import CoreMedia

public struct FrameTimebase {
    public enum RoundingMode {
        case floor
        case nearest
        case ceil
    }

    public struct Rational: Sendable, Equatable {
        public let numerator: Int64
        public let denominator: Int64

        public init(numerator: Int64, denominator: Int64) {
            precondition(denominator != 0, "Denominator must not be zero")
            let sign = denominator < 0 ? -1 : 1
            self.numerator = numerator * Int64(sign)
            self.denominator = abs(denominator)
        }

        public func reduced() -> Rational {
            let divisor = Rational.gcd(abs(numerator), denominator)
            guard divisor > 1 else { return self }
            return Rational(numerator: numerator / divisor, denominator: denominator / divisor)
        }

        public var doubleValue: Double {
            Double(numerator) / Double(denominator)
        }

        private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
            var a = a
            var b = b
            while b != 0 {
                let remainder = a % b
                a = b
                b = remainder
            }
            return a
        }
    }

    public let framesPerSecond: Rational
    public let secondsPerFrame: Rational
    public let frameDuration: CMTime

    public init(frameRate: Double) {
        let fpsRational = FrameTimebase.rationalFramesPerSecond(for: frameRate)
        framesPerSecond = fpsRational.reduced()
        secondsPerFrame = Rational(numerator: framesPerSecond.denominator,
                                   denominator: framesPerSecond.numerator).reduced()
        frameDuration = CMTime(value: secondsPerFrame.numerator,
                               timescale: Int32(clamping: secondsPerFrame.denominator))
    }

    public func frameIndex(for time: TimeInterval, rounding mode: RoundingMode = .nearest) -> Int64 {
        guard time.isFinite else { return 0 }
        let clamped = max(time, 0)
        // Use CMTime to preserve rationals as much as possible.
        let preferredTimescale = Int32(clamping: max(1, min(Int64(secondsPerFrame.denominator), Int64(Int32.max))))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: preferredTimescale)

        let numerator = Int64(cmTime.value) * framesPerSecond.numerator
        let denominator = Int64(cmTime.timescale) * framesPerSecond.denominator
        guard denominator != 0 else { return 0 }

        let quotient = numerator / denominator
        let remainder = numerator % denominator

        switch mode {
        case .floor:
            return quotient
        case .ceil:
            if remainder == 0 { return quotient }
            return quotient + 1
        case .nearest:
            if remainder == 0 { return quotient }
            let offset: Int64 = abs(remainder) * 2 >= abs(denominator) ? 1 : 0
            return quotient + offset * (numerator >= 0 ? 1 : -1)
        }
    }

    public func time(forFrameIndex index: Int64) -> TimeInterval {
        guard index > 0 else { return 0 }
        let value = secondsPerFrame.numerator * index
        let cmTime = CMTime(value: value,
                            timescale: Int32(clamping: secondsPerFrame.denominator))
        return cmTime.seconds
    }

    public func quantize(_ time: TimeInterval, rounding mode: RoundingMode = .nearest) -> TimeInterval {
        let index = frameIndex(for: time, rounding: mode)
        return self.time(forFrameIndex: index)
    }

    private static func rationalFramesPerSecond(for fps: Double) -> Rational {
        guard fps.isFinite, fps > 0 else { return Rational(numerator: 24, denominator: 1) }

        let known: [(Double, Rational)] = [
            (24000.0 / 1001.0, Rational(numerator: 24000, denominator: 1001)),
            (30000.0 / 1001.0, Rational(numerator: 30000, denominator: 1001)),
            (60000.0 / 1001.0, Rational(numerator: 60000, denominator: 1001)),
            (24.0, Rational(numerator: 24, denominator: 1)),
            (25.0, Rational(numerator: 25, denominator: 1)),
            (30.0, Rational(numerator: 30, denominator: 1)),
            (48.0, Rational(numerator: 48, denominator: 1)),
            (50.0, Rational(numerator: 50, denominator: 1)),
            (60.0, Rational(numerator: 60, denominator: 1))
        ]

        if let match = known.first(where: { abs($0.0 - fps) <= 0.0005 }) {
            return match.1
        }

        // Fallback: approximate using 1000-title denominator to avoid huge numbers, then reduce.
        let scaledNumerator = Int64((fps * 1000.0).rounded())
        guard scaledNumerator > 0 else { return Rational(numerator: 24, denominator: 1) }
        return Rational(numerator: scaledNumerator, denominator: 1000).reduced()
    }
}

private extension Int32 {
    init(clamping source: Int64) {
        if source > Int64(Int32.max) {
            self = Int32.max
        } else if source < Int64(Int32.min) {
            self = Int32.min
        } else {
            self = Int32(source)
        }
    }
}
