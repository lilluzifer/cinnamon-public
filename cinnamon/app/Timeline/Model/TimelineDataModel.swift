import Foundation
import AVFoundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum TrackKind: String, Codable, Sendable {
    case video
    case audio
}

public struct Track: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var stackIndex: Int
    public var kind: TrackKind
    public var name: String
    public var muted: Bool
    public var solo: Bool
    public var locked: Bool
    public var colorHex: String
    public var blendMode: BlendMode

    public init(id: UUID = UUID(),
                stackIndex: Int,
                kind: TrackKind,
                name: String,
                muted: Bool = false,
                solo: Bool = false,
                locked: Bool = false,
                color: Color = .gray,
                blendMode: BlendMode = .normal) {
        self.id = id
        self.stackIndex = stackIndex
        self.kind = kind
        self.name = name
        self.muted = muted
        self.solo = solo
        self.locked = locked
        self.colorHex = color.toHexString()
        self.blendMode = blendMode
    }

    public var color: Color { Color(hex: colorHex) }

    private enum CodingKeys: String, CodingKey {
        case id
        case stackIndex
        case kind
        case name
        case muted
        case solo
        case locked
        case colorHex
        case blendMode
        case legacyIndex = "index"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let decodedStackIndex = try container.decodeIfPresent(Int.self, forKey: .stackIndex) {
            stackIndex = decodedStackIndex
        } else {
            stackIndex = try container.decode(Int.self, forKey: .legacyIndex)
        }
        kind = try container.decode(TrackKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        muted = try container.decode(Bool.self, forKey: .muted)
        solo = try container.decode(Bool.self, forKey: .solo)
        locked = try container.decode(Bool.self, forKey: .locked)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        blendMode = try container.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stackIndex, forKey: .stackIndex)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(muted, forKey: .muted)
        try container.encode(solo, forKey: .solo)
        try container.encode(locked, forKey: .locked)
        try container.encode(colorHex, forKey: .colorHex)
        if blendMode != .normal {
            try container.encode(blendMode, forKey: .blendMode)
        }
    }
}


public enum TrackMatteMode: String, Codable, Sendable, CaseIterable {
    case none
    case alpha
    case alphaInverted
    case luma
    case lumaInverted

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .alpha: return "Alpha Matte"
        case .alphaInverted: return "Alpha Inverted Matte"
        case .luma: return "Luma Matte"
        case .lumaInverted: return "Luma Inverted Matte"
        }
    }
}

public struct Marker: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var time: TimeInterval
    public var name: String
    public var colorHex: String

    public init(id: UUID = UUID(), time: TimeInterval, name: String, color: Color = .yellow) {
        self.id = id
        self.time = time
        self.name = name
        self.colorHex = color.toHexString()
    }

    public var color: Color { Color(hex: colorHex) }
}

/// Half-open clip representation (`[dstStart, dstEnd)`).
public struct Clip: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var assetRef: String
    public var srcRange: CMTimeRange
    public var dstStart: TimeInterval
    public var enabled: Bool
    public var audioTrackIndex: Int?
    public var videoTrackIndex: Int?
    public var speed: Float
    public var transform: Transform2D
    public var transformRef: UUID?
    public var metadata: ClipMetadata
    public var matteMode: TrackMatteMode
    public var matteSourceID: UUID?
    public var useLayerAbove: Bool
    public var hideAsRender: Bool

    public init(id: UUID = UUID(),
                name: String,
                assetRef: String,
                srcRange: CMTimeRange,
                dstStart: TimeInterval,
                enabled: Bool = true,
                audioTrackIndex: Int? = nil,
                videoTrackIndex: Int? = nil,
                speed: Float = 1.0,
                transform: Transform2D = Transform2D(),
                transformRef: UUID? = nil,
                metadata: ClipMetadata = ClipMetadata(),
                matteMode: TrackMatteMode = .none,
                matteSourceID: UUID? = nil,
                useLayerAbove: Bool = false,
                hideAsRender: Bool = false) {
        self.id = id
        self.name = name
        self.assetRef = assetRef
        self.srcRange = srcRange
        self.dstStart = dstStart
        self.enabled = enabled
        self.audioTrackIndex = audioTrackIndex
        self.videoTrackIndex = videoTrackIndex
        self.speed = speed
        self.transform = transform
        self.transformRef = transformRef
        self.metadata = metadata
        self.matteMode = matteMode
        self.matteSourceID = matteSourceID
        self.useLayerAbove = useLayerAbove
        self.hideAsRender = hideAsRender
    }

    public var duration: TimeInterval {
        let seconds = srcRange.duration.seconds / Double(max(speed, 0.0001))
        return max(0, seconds)
    }

    public var dstEnd: TimeInterval { dstStart + duration }
}

extension Clip: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, assetRef, srcStart, srcDuration, dstStart, enabled, audioTrackIndex, videoTrackIndex, speed, transform, transformRef, metadata, matteMode, matteSourceID, useLayerAbove, hideAsRender }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        assetRef = try container.decode(String.self, forKey: .assetRef)
        let startSeconds = try container.decode(Double.self, forKey: .srcStart)
        var durationSeconds = try container.decode(Double.self, forKey: .srcDuration)

        // Validate duration without fallback - fail if invalid
        guard durationSeconds > 0, durationSeconds.isFinite else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid clip duration: \(durationSeconds)"
            ))
        }

        srcRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                               duration: CMTime(seconds: durationSeconds, preferredTimescale: 600))
        dstStart = try container.decode(Double.self, forKey: .dstStart)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        audioTrackIndex = try container.decodeIfPresent(Int.self, forKey: .audioTrackIndex)
        videoTrackIndex = try container.decodeIfPresent(Int.self, forKey: .videoTrackIndex)
        speed = try container.decode(Float.self, forKey: .speed)
        transform = try container.decodeIfPresent(Transform2D.self, forKey: .transform) ?? Transform2D()
        transformRef = try container.decodeIfPresent(UUID.self, forKey: .transformRef)
        metadata = try container.decodeIfPresent(ClipMetadata.self, forKey: .metadata) ?? ClipMetadata()
        matteMode = try container.decodeIfPresent(TrackMatteMode.self, forKey: .matteMode) ?? .none
        matteSourceID = try container.decodeIfPresent(UUID.self, forKey: .matteSourceID)
        useLayerAbove = try container.decodeIfPresent(Bool.self, forKey: .useLayerAbove) ?? false
        hideAsRender = try container.decodeIfPresent(Bool.self, forKey: .hideAsRender) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(assetRef, forKey: .assetRef)
        try container.encode(srcRange.start.seconds, forKey: .srcStart)
        try container.encode(srcRange.duration.seconds, forKey: .srcDuration)
        try container.encode(dstStart, forKey: .dstStart)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(audioTrackIndex, forKey: .audioTrackIndex)
        try container.encodeIfPresent(videoTrackIndex, forKey: .videoTrackIndex)
        try container.encode(speed, forKey: .speed)
        try container.encode(transform, forKey: .transform)
        try container.encodeIfPresent(transformRef, forKey: .transformRef)
        try container.encode(metadata, forKey: .metadata)
        if matteMode != .none {
            try container.encode(matteMode, forKey: .matteMode)
        }
        try container.encodeIfPresent(matteSourceID, forKey: .matteSourceID)
        if useLayerAbove {
            try container.encode(useLayerAbove, forKey: .useLayerAbove)
        }
        if hideAsRender {
            try container.encode(hideAsRender, forKey: .hideAsRender)
        }
    }
}

public enum AEEditType: String, CaseIterable, Sendable {
    case split, join, trimIn, trimOut
    case move, slip, slide, roll
    case rippleInsert, rippleDelete, lift, extract
    case timeStretch, timeRemap, reverse
    case reorderLayers
    case layerSwitches
}

public struct ClipMetadata: Codable, Equatable, Sendable {
    public var originalSrcStart: TimeInterval?
    public var originalDstStart: TimeInterval?
    public var userMetadata: [String: String]

    public init(originalSrcStart: TimeInterval? = nil,
                originalDstStart: TimeInterval? = nil,
                userMetadata: [String: String] = [:]) {
        self.originalSrcStart = originalSrcStart
        self.originalDstStart = originalDstStart
        self.userMetadata = userMetadata
    }
}

public struct TimelineKeyframeTrack: Codable, Equatable, Sendable {
    public let id: UUID
    public var layerID: UUID
    public var propertyPath: String
    public var keyframes: [TimelineKeyframe]

    public init(id: UUID = UUID(),
                layerID: UUID,
                propertyPath: String,
                keyframes: [TimelineKeyframe] = []) {
        self.id = id
        self.layerID = layerID
        self.propertyPath = propertyPath
        self.keyframes = keyframes
    }
}

public struct TimelineKeyframe: Codable, Equatable, Sendable {
    public let id: UUID
    public var time: TimeInterval
    public var value: Float

    public init(id: UUID = UUID(), time: TimeInterval, value: Float) {
        self.id = id
        self.time = time
        self.value = value
    }
}

public struct Composition: Equatable, Sendable {
    public var frameRate: Double
    public var duration: TimeInterval
    public var tracks: [Track]
    public var clips: [Clip]
    public var markers: [Marker]
    public var workArea: CMTimeRange?
    public var keyframeTracks: [TimelineKeyframeTrack]

    public init(frameRate: Double,
                duration: TimeInterval,
                tracks: [Track] = [],
                clips: [Clip] = [],
                markers: [Marker] = [],
                workArea: CMTimeRange? = nil,
                keyframeTracks: [TimelineKeyframeTrack] = []) {
        self.frameRate = frameRate
        self.duration = duration
        self.tracks = tracks
        self.clips = clips
        self.markers = markers
        self.workArea = workArea
        self.keyframeTracks = keyframeTracks
    }
}

extension Composition {
    func updating(clips newClips: [Clip], keyframeTracks newTracks: [TimelineKeyframeTrack]? = nil) -> Composition {
        Composition(frameRate: frameRate,
                    duration: duration,
                    tracks: tracks,
                    clips: newClips.sorted { $0.dstStart < $1.dstStart },
                    markers: markers,
                    workArea: workArea,
                    keyframeTracks: newTracks ?? keyframeTracks)
    }

    func updating(clips newClips: [Clip], tracks newTracks: [Track], keyframeTracks newKeyframeTracks: [TimelineKeyframeTrack]? = nil) -> Composition {
        Composition(frameRate: frameRate,
                    duration: duration,
                    tracks: newTracks,
                    clips: newClips.sorted { $0.dstStart < $1.dstStart },
                    markers: markers,
                    workArea: workArea,
                    keyframeTracks: newKeyframeTracks ?? keyframeTracks)
    }

    func updatingClips(_ clips: [Clip]) -> Composition {
        updating(clips: clips, keyframeTracks: keyframeTracks)
    }
}

extension Composition {
    var frameTimebase: FrameTimebase {
        FrameTimebase(frameRate: frameRate)
    }
}

extension Clip {
    var effectiveSpeed: Double { Double(max(speed, 0.0001)) }

    func trimmed(toFrameRange frameRange: Range<Int64>,
                 preserveID: Bool,
                 using timebase: FrameTimebase) -> Clip {
        guard frameRange.upperBound > frameRange.lowerBound else { return self }

        let startFrame = max(frameRange.lowerBound, 0)
        let endFrame = max(frameRange.upperBound, startFrame)
        let frameCount = max(endFrame - startFrame, duration > 0 ? 1 : 0)

        let newDstStart = timebase.time(forFrameIndex: startFrame)
        let dstDuration = Double(frameCount) * timebase.frameDuration.seconds

        let originalStartFrame = timebase.frameIndex(for: dstStart, rounding: .nearest)
        let frameDelta = startFrame - originalStartFrame
        let timelineDelta = Double(frameDelta) * timebase.frameDuration.seconds

        let originalSrcStart = srcRange.start.seconds
        let timescale = srcRange.duration.timescale != 0 ? srcRange.duration.timescale : 600

        let srcStartSeconds = originalSrcStart + timelineDelta * effectiveSpeed
        let srcDurationSeconds = dstDuration * effectiveSpeed

        let newRange = CMTimeRange(start: CMTime(seconds: srcStartSeconds,
                                                preferredTimescale: timescale),
                                   duration: CMTime(seconds: srcDurationSeconds,
                                                    preferredTimescale: timescale))

        return Clip(id: preserveID ? id : UUID(),
                    name: name,
                    assetRef: assetRef,
                    srcRange: newRange,
                    dstStart: newDstStart,
                    enabled: enabled,
                    audioTrackIndex: audioTrackIndex,
                    videoTrackIndex: videoTrackIndex,
                    speed: speed,
                    transform: transform,
                    transformRef: transformRef,
                    metadata: metadata,
                    matteMode: matteMode,
                    matteSourceID: matteSourceID,
                    useLayerAbove: useLayerAbove,
                    hideAsRender: hideAsRender)
    }

    func quantized(using timebase: FrameTimebase) -> Clip {
        let startFrame = timebase.frameIndex(for: dstStart, rounding: .nearest)
        let endFrame = timebase.frameIndex(for: dstEnd, rounding: .ceil)
        let quantizedStart = timebase.time(forFrameIndex: startFrame)
        let frameCount = max(endFrame - startFrame, duration > 0 ? 1 : 0)
        let durationSeconds = Double(frameCount) * timebase.frameDuration.seconds

        let originalStartFrame = timebase.frameIndex(for: dstStart, rounding: .nearest)
        let frameDelta = startFrame - originalStartFrame
        let timelineDelta = Double(frameDelta) * timebase.frameDuration.seconds
        let timescale = srcRange.duration.timescale != 0 ? srcRange.duration.timescale : 600

        let srcStartSeconds = srcRange.start.seconds + timelineDelta * effectiveSpeed
        let srcDurationSeconds = durationSeconds * effectiveSpeed

        let newRange = CMTimeRange(start: CMTime(seconds: srcStartSeconds,
                                                preferredTimescale: timescale),
                                   duration: CMTime(seconds: srcDurationSeconds,
                                                    preferredTimescale: timescale))

        return Clip(id: id,
                    name: name,
                    assetRef: assetRef,
                    srcRange: newRange,
                    dstStart: quantizedStart,
                    enabled: enabled,
                    audioTrackIndex: audioTrackIndex,
                    videoTrackIndex: videoTrackIndex,
                    speed: speed,
                    transform: transform,
                    transformRef: transformRef,
                    metadata: metadata,
                    matteMode: matteMode,
                    matteSourceID: matteSourceID,
                    useLayerAbove: useLayerAbove,
                    hideAsRender: hideAsRender)
    }
}

extension Composition {
    func quantizedForTimeline(requestedDuration: TimeInterval? = nil) -> Composition {
        let timebase = frameTimebase
        let quantizedClips = clips.map { $0.quantized(using: timebase) }
        let quantizedMarkers = markers.map { marker -> Marker in
            var copy = marker
            copy.time = timebase.quantize(marker.time, rounding: .nearest)
            return copy
        }

        var result = Composition(frameRate: frameRate,
                                 duration: duration,
                                 tracks: tracks,
                                 clips: quantizedClips.sorted { $0.dstStart < $1.dstStart },
                                 markers: quantizedMarkers,
                                 workArea: workArea,
                                 keyframeTracks: keyframeTracks)

        if let workArea {
            let start = timebase.quantize(workArea.start.seconds, rounding: .floor)
            let end = timebase.quantize(workArea.end.seconds, rounding: .ceil)
            if end > start {
                result.workArea = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                              duration: CMTime(seconds: end - start, preferredTimescale: 600))
            } else {
                result.workArea = nil
            }
        }

        let maxClipFrame = quantizedClips
            .map { timebase.frameIndex(for: $0.dstEnd, rounding: .ceil) }
            .max() ?? 0
        let requestedFrame = timebase.frameIndex(for: requestedDuration ?? duration, rounding: .ceil)
        let durationFrame = max(requestedFrame, maxClipFrame)
        result.duration = timebase.time(forFrameIndex: durationFrame)

        return result
    }
}

extension Composition: Codable {
    private enum CodingKeys: String, CodingKey { case frameRate, duration, tracks, clips, markers, workAreaStart, workAreaDuration, keyframeTracks }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try container.decode(Double.self, forKey: .frameRate)
        duration = try container.decode(Double.self, forKey: .duration)
        tracks = try container.decode([Track].self, forKey: .tracks)
        clips = try container.decode([Clip].self, forKey: .clips)
        markers = try container.decode([Marker].self, forKey: .markers)
        keyframeTracks = try container.decodeIfPresent([TimelineKeyframeTrack].self, forKey: .keyframeTracks) ?? []

        if let start = try container.decodeIfPresent(Double.self, forKey: .workAreaStart),
           let durationValue = try container.decodeIfPresent(Double.self, forKey: .workAreaDuration) {
            workArea = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                   duration: CMTime(seconds: durationValue, preferredTimescale: 600))
        } else {
            workArea = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(duration, forKey: .duration)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(clips, forKey: .clips)
        try container.encode(markers, forKey: .markers)
        try container.encode(keyframeTracks, forKey: .keyframeTracks)
        if let workArea {
            try container.encode(workArea.start.seconds, forKey: .workAreaStart)
            try container.encode(workArea.duration.seconds, forKey: .workAreaDuration)
        }
    }
}

// MARK: - Asset Duration Registry

public class AssetDurationRegistry {
    public static let shared = AssetDurationRegistry()

    private var durationsByAbsolute: [String: TimeInterval] = [:]
    private var durationsByBasename: [String: TimeInterval] = [:]
    private var durationsByIdentifier: [String: TimeInterval] = [:]
    private let _durationTolerance: TimeInterval = 1.0 / 60.0

    private init() {}

    public var durationTolerance: TimeInterval { _durationTolerance }

    public func identifier(for url: URL) -> String {
        return Self.makeIdentifier(for: url)
    }

    public func register(url: URL, identifier: String? = nil, duration: TimeInterval, allowOverwrite: Bool = true) {
        guard duration > 0, duration.isFinite else { return }

        let absoluteKey = url.absoluteString
        updateStorage(&durationsByAbsolute, key: absoluteKey, value: duration, allowOverwrite: allowOverwrite)

        let basenameKey = url.lastPathComponent
        updateStorage(&durationsByBasename, key: basenameKey, value: duration, allowOverwrite: allowOverwrite)

        let resolvedIdentifier = identifier ?? Self.makeIdentifier(for: url)
        updateStorage(&durationsByIdentifier, key: resolvedIdentifier, value: duration, allowOverwrite: allowOverwrite)
    }

    private func updateStorage(_ storage: inout [String: TimeInterval],
                               key: String,
                               value: TimeInterval,
                               allowOverwrite: Bool) {
        guard allowOverwrite else {
            if storage[key] == nil {
                storage[key] = value
            }
            return
        }

        if let existing = storage[key] {
            if abs(existing - value) <= _durationTolerance { return }
        }
        storage[key] = value
    }

    public func duration(for clip: Clip) -> TimeInterval? {
        prime(from: clip)

        if let assetID = clip.metadata.userMetadata["assetID"],
           let duration = durationsByIdentifier[assetID] {
            return duration
        }

        if let absoluteURL = URL(string: clip.assetRef)?.absoluteString,
           let duration = durationsByAbsolute[absoluteURL] {
            return duration
        }

        if let basename = URL(string: clip.assetRef)?.lastPathComponent,
           let duration = durationsByBasename[basename] {
            return duration
        }

        if let storedDuration = clip.metadata.userMetadata["assetDuration"],
           let duration = TimeInterval(storedDuration),
           duration > 0,
           duration.isFinite {
            return duration
        }

        return nil
    }

    public func measuredDuration(for url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        guard duration.isValid, duration.isNumeric else {
            if ClipSanitizer.debugEnabled {
                print("[SAN] measuredDuration invalid duration for url=\(url)")
            }
            return nil
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            if ClipSanitizer.debugEnabled {
                print("[SAN] measuredDuration non-finite or <=0 for url=\(url) value=\(seconds)")
            }
            return nil
        }

        register(url: url, duration: seconds, allowOverwrite: true)
        if ClipSanitizer.debugEnabled {
            print("[SAN] measuredDuration url=\(url) seconds=\(seconds)")
        }
        return seconds
    }

    public func prime(from clip: Clip) {
        guard let durationString = clip.metadata.userMetadata["assetDuration"],
              let duration = TimeInterval(durationString),
              duration > 0,
              duration.isFinite else {
            return
        }

        if let assetID = clip.metadata.userMetadata["assetID"],
           !assetID.isEmpty,
           durationsByIdentifier[assetID] == nil {
            durationsByIdentifier[assetID] = duration
        }

        if let storedURL = clip.metadata.userMetadata["assetURL"],
           let url = URL(string: storedURL) {
            register(url: url,
                     identifier: clip.metadata.userMetadata["assetID"],
                     duration: duration,
                     allowOverwrite: false)
            return
        }

        if let url = URL(string: clip.assetRef) {
            register(url: url,
                     identifier: clip.metadata.userMetadata["assetID"],
                     duration: duration,
                     allowOverwrite: false)
            return
        }

        if let assetID = clip.metadata.userMetadata["assetID"], !assetID.isEmpty {
            if durationsByIdentifier[assetID] == nil {
                durationsByIdentifier[assetID] = duration
            }
            return
        }

        let basename = (URL(string: clip.assetRef)?.lastPathComponent) ?? clip.assetRef
        if durationsByBasename[basename] == nil {
            durationsByBasename[basename] = duration
        }
    }

    public func duration(forAssetRef assetRef: String) -> TimeInterval? {
        if let duration = durationsByAbsolute[assetRef] {
            return duration
        }
        if let duration = durationsByBasename[assetRef] {
            return duration
        }
        return nil
    }

    public func clear() {
        durationsByAbsolute.removeAll()
        durationsByBasename.removeAll()
        durationsByIdentifier.removeAll()
    }

    private static func makeIdentifier(for url: URL) -> String {
        let data = Array(url.standardizedFileURL.path.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Clip Sanitizer

public struct ClipSanitizer {
    public static let maxFallbackDuration: TimeInterval = 3600

    public static let debugEnabled = ProcessInfo.processInfo.environment["CIN_TIMELINE_DEBUG"] == "1"

    public static func sanitize(_ clip: Clip,
                                frameTimebase: FrameTimebase,
                                registry: AssetDurationRegistry = .shared) -> Clip {
        var sanitized = clip

        // Use video layer framerate for clip validation (MIN of original and global)
        let videoLayerFrameRate: Double
        if let layerRateString = clip.metadata.userMetadata["videoLayerFrameRate"],
           let layerRate = Double(layerRateString), layerRate > 0 {
            videoLayerFrameRate = layerRate
        } else if let nativeRateString = clip.metadata.userMetadata["videoNativeFrameRate"],
                  let nativeRate = Double(nativeRateString), nativeRate > 0 {
            // After Effects: use native framerate
            videoLayerFrameRate = nativeRate
        } else {
            // Last fallback to 24fps
            videoLayerFrameRate = 24.0
        }
        let frameDuration = max(1.0 / videoLayerFrameRate, 1e-6)
        let changeTolerance = frameDuration * 0.5
        let originalSrcStart = clip.srcRange.start.seconds
        let originalSrcDuration = clip.srcRange.duration.seconds

        let storedDurationString = clip.metadata.userMetadata["assetDuration"]
        let storedDuration = storedDurationString.flatMap(TimeInterval.init)
        let originalDuration = clip.metadata.userMetadata["assetDurationOriginal"].flatMap(TimeInterval.init)

        registry.prime(from: clip)

        let timelineDuration = max(frameDuration, clip.dstEnd - clip.dstStart)
        let speed = clip.effectiveSpeed

        var srcStart = originalSrcStart
        if !srcStart.isFinite || srcStart < 0 {
            srcStart = max(0, srcStart.isFinite ? srcStart : 0)
        }

        var assetDuration = registry.duration(for: clip) ?? storedDuration ?? originalDuration
        var measuredDuration: TimeInterval? = nil
        if let url = URL(string: clip.assetRef) {
            measuredDuration = registry.measuredDuration(for: url)
            if let measured = measuredDuration {
                if let resolved = assetDuration {
                    if abs(resolved - measured) > registry.durationTolerance {
                        assetDuration = measured
                    }
                } else {
                    assetDuration = measured
                }
            }
        }
        var usedFallbackDuration = false
        if assetDuration == nil {
            if let url = URL(string: clip.assetRef) {
                if let measured = registry.measuredDuration(for: url) {
                    assetDuration = max(frameDuration, measured)
                }
            }

            if assetDuration == nil {
                let inferred = max(srcStart + max(originalSrcDuration, frameDuration), timelineDuration * speed)
                let bounded = max(frameDuration, inferred)
                assetDuration = min(bounded, maxFallbackDuration)
                usedFallbackDuration = true
            }
        }

        let resolvedAssetDuration = max(frameDuration, assetDuration ?? frameDuration)
        let maxSrcStart = max(0, resolvedAssetDuration - frameDuration)
        let clampedSrcStart = min(max(0, srcStart), maxSrcStart)

        var srcDuration = originalSrcDuration
        if !srcDuration.isFinite || srcDuration <= 0 {
            srcDuration = timelineDuration * speed
        }

        let availableDuration = max(frameDuration, resolvedAssetDuration - clampedSrcStart)
        let minimumSrcDuration = frameDuration * speed
        let clampedSrcDuration = min(max(minimumSrcDuration, srcDuration), availableDuration)

        let startTimescale = clip.srcRange.start.timescale != 0 ? clip.srcRange.start.timescale : 600
        let durationTimescale = clip.srcRange.duration.timescale != 0 ? clip.srcRange.duration.timescale : 600

        let newRange = CMTimeRange(start: CMTime(seconds: clampedSrcStart, preferredTimescale: startTimescale),
                                   duration: CMTime(seconds: clampedSrcDuration, preferredTimescale: durationTimescale))

        if sanitized.srcRange != newRange {
            sanitized.srcRange = newRange
        }

        if !sanitized.dstStart.isFinite || sanitized.dstStart < 0 {
            if debugEnabled {
                print("[SAN] clip=\(clip.id) dstStart=\(clip.dstStart) → 0")
            }
            sanitized.dstStart = 0
        }

        let dstDuration = sanitized.dstEnd - sanitized.dstStart
        let minimumDstDuration = frameDuration
        if dstDuration + changeTolerance < minimumDstDuration {
            let fallbackSrcDuration = min(max(minimumSrcDuration, sanitized.srcRange.duration.seconds), availableDuration)
            if abs(fallbackSrcDuration - sanitized.srcRange.duration.seconds) > changeTolerance {
                let durationTimescale = sanitized.srcRange.duration.timescale != 0 ? sanitized.srcRange.duration.timescale : 600
                sanitized.srcRange.duration = CMTime(seconds: fallbackSrcDuration,
                                                     preferredTimescale: durationTimescale)
                if debugEnabled {
                    print("[SAN] clip=\(clip.id) duration enforced to ≥1 frame")
                }
            }
        }

        var metadata = sanitized.metadata
        if let measured = measuredDuration {
            metadata.userMetadata["assetDuration"] = String(measured)
        } else if let existing = storedDurationString, usedFallbackDuration {
            metadata.userMetadata["assetDuration"] = existing
        } else {
            metadata.userMetadata["assetDuration"] = String(resolvedAssetDuration)
        }
        if !usedFallbackDuration || measuredDuration != nil {
            if metadata.userMetadata["assetDurationOriginal"] == nil {
                if let originalDuration {
                    metadata.userMetadata["assetDurationOriginal"] = String(originalDuration)
                } else if let measured = measuredDuration {
                    metadata.userMetadata["assetDurationOriginal"] = String(measured)
                } else {
                    metadata.userMetadata["assetDurationOriginal"] = String(resolvedAssetDuration)
                }
            }
        }
        if metadata.userMetadata["assetURL"] == nil {
            metadata.userMetadata["assetURL"] = sanitized.assetRef
        }
        if metadata.userMetadata["assetID"] == nil,
           let url = URL(string: sanitized.assetRef) {
            metadata.userMetadata["assetID"] = registry.identifier(for: url)
        }
        sanitized.metadata = metadata

        if !usedFallbackDuration {
            registry.prime(from: sanitized)
        }

        if debugEnabled {
            let startChanged = abs(originalSrcStart - sanitized.srcRange.start.seconds) > changeTolerance
            let durChanged = abs(originalSrcDuration - sanitized.srcRange.duration.seconds) > changeTolerance
            if startChanged || durChanged {
                print("[SAN] clip=\(clip.id) assetRef=\(clip.assetRef) src=(\(originalSrcStart), \(originalSrcDuration)) → (\(sanitized.srcRange.start.seconds), \(sanitized.srcRange.duration.seconds)) measured=\(String(describing: measuredDuration)) stored=\(String(describing: storedDuration)) original=\(String(describing: originalDuration)) fallback=\(usedFallbackDuration)")
            }
            if measuredDuration == nil, assetDuration == nil {
                print("[SAN] WARN: no duration available for clip=\(clip.id) assetRef=\(clip.assetRef)")
            }
        }

        // Sanitize matte settings
        if sanitized.matteSourceID == sanitized.id {
            // Prevent self-reference
            sanitized.matteSourceID = nil
            sanitized.matteMode = .none
        }

        return sanitized
    }
}

// MARK: - Matte Validation

extension Composition {
    /// Sanitize all clips to ensure valid matte references
    public func sanitizeMatteSources() -> Composition {
        var sanitized = self
        var clipsByID: [UUID: Clip] = [:]
        for clip in clips {
            clipsByID[clip.id] = clip
        }

        let frameDuration = frameRate > 0 ? 1.0 / frameRate : 1.0 / 24.0
        let epsilon = max(frameDuration * 0.5, 1e-6)
        let debugEnabled = ProcessInfo.processInfo.environment["CIN_TIMELINE_DEBUG"] == "1"

        func hasCycle(from clipID: UUID, chain: Set<UUID>) -> Bool {
            guard let clip = clipsByID[clipID] else { return false }
            guard let matteID = clip.matteSourceID else { return false }

            if chain.contains(matteID) {
                return true // Found a cycle
            }

            var newChain = chain
            newChain.insert(matteID)
            return hasCycle(from: matteID, chain: newChain)
        }

        for i in 0..<sanitized.clips.count {
            var clip = sanitized.clips[i]
            var changed = false

            if let matteID = clip.matteSourceID {
                let invalidateMatte: () -> Void = {
                    clip.matteSourceID = nil
                    clip.matteMode = .none
                    changed = true
                    clipsByID[clip.id] = clip
                }

                if matteID == clip.id {
                    invalidateMatte()
                } else if clipsByID[matteID] == nil {
                    invalidateMatte()
                } else if hasCycle(from: clip.id, chain: [clip.id]) {
                    invalidateMatte()
                } else if let matteClip = clipsByID[matteID] {
                    if matteClip.matteMode == .none {
                        invalidateMatte()
                    } else {
                        let latestStart = max(clip.dstStart, matteClip.dstStart)
                        let earliestEnd = min(clip.dstEnd, matteClip.dstEnd)
                        let overlap = earliestEnd - latestStart
                        if overlap <= epsilon {
                            invalidateMatte()
                        }
                    }
                }
            }

            if clip.useLayerAbove && clip.matteMode != .none {
                if clip.matteSourceID != nil {
                    clip.matteSourceID = nil
                    changed = true
                }
            }

            if changed, debugEnabled {
                print("[SAN] matte reset clip=\(clip.id)")
            }

            sanitized.clips[i] = clip
            clipsByID[clip.id] = clip
        }

        return sanitized
    }
}

// MARK: - Helpers

private extension Color {
    func toHexString() -> String {
        #if canImport(AppKit)
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        #else
        return "#808080"
        #endif
    }

    init(hex: String) {
        #if canImport(AppKit)
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
        #else
        self = .gray
        #endif
    }
}
