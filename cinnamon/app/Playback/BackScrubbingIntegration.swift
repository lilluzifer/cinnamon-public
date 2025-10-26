//
//  BackScrubbingIntegration.swift
//  cinnamon
//
//  Integration point for new back-scrubbing components
//

import Foundation
import AVFoundation
import CoreVideo
import Metal

// MARK: - Back-Scrubbing Components Registry

/// Registry for all back-scrubbing optimization components
/// This file ensures all new components are properly linked
@MainActor
final class BackScrubbingIntegration {

    // Component references to ensure they're compiled
    static let pixelBufferPool = ZeroCopyPixelBufferPool.shared
    static let qosManager = QualityOfServiceManager.shared
    static let iframeManager = IFrameIndexManager.shared
    static let frameServer = FrameServer.shared
    static let telemetry = PerformanceTelemetry.shared
    static let dirtyTracker = DirtyRegionTracker()

    /// Initialize back-scrubbing subsystems
    static func initialize() {
        print("[BackScrubbing] Initializing optimized components...")

        // Warm up pools
        Task {
            _ = await pixelBufferPool.getStatistics()
            // Note: Real initialization would use actual assets
            // _ = await iframeManager.getIndex(for: asset, track: track)
            _ = await frameServer.getCacheStatistics()
        }

        print("[BackScrubbing] Components initialized")
    }

    /// Create optimized mini-GOP buffer for asset
    static func createMiniGOPBuffer(for asset: AVAsset, track: AVAssetTrack) -> MiniGOPRingBuffer {
        return MiniGOPRingBuffer.createOptimized(for: asset, track: track)
    }
}
