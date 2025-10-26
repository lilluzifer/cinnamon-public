import Foundation
import CoreVideo
import AVFoundation
import os

/// Asynchronous frame pipeline that decouples decoding from rendering
/// Maintains multiple frame buffers for smooth playback without blocking
final class FramePipeline {

    struct PipelineFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: TimeInterval
        let clipID: UUID
    }

    /// Ring buffer for decoded frames
    private class FrameRing {
        private struct Storage {
            var frames: [PipelineFrame?]
            var writeIndex: Int
            let capacity: Int
        }

        private let lock: OSAllocatedUnfairLock<Storage>

        init(capacity: Int = 12) {
            lock = .init(initialState: Storage(frames: Array(repeating: nil, count: capacity),
                                               writeIndex: 0,
                                               capacity: capacity))
        }

        func write(_ frame: PipelineFrame) -> Bool {
            lock.withLock { storage in
                storage.frames[storage.writeIndex] = frame
                storage.writeIndex = (storage.writeIndex + 1) % storage.capacity
                return true
            }
        }

        func read(for time: TimeInterval) -> PipelineFrame? {
            lock.withLock { storage in
                var bestFrame: PipelineFrame?
                var smallestPositiveDiff = Double.infinity

                // NEAREST-PREVIOUS: Find the frame with PTS <= time that's closest to time
                for frame in storage.frames.compactMap({ $0 }) {
                    let diff = time - frame.presentationTime
                    
                    // Only consider frames at or before the requested time
                    if diff >= 0 && diff < smallestPositiveDiff {
                        smallestPositiveDiff = diff
                        bestFrame = frame
                    }
                }

                return bestFrame
            }
        }

        func clear() {
            lock.withLock { storage in
                storage.frames = Array(repeating: nil, count: storage.capacity)
                storage.writeIndex = 0
            }
        }
    }

    private let pipelinesLock = OSAllocatedUnfairLock<[UUID: FrameRing]>(initialState: [:])
    private let decodeTasksLock = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])
    private let clipTimelineRanges = OSAllocatedUnfairLock<[UUID: ClosedRange<TimeInterval>]>(initialState: [:])

    // Target number of frames to hold ahead of the playhead
    private let lookAheadFrameFactor: Double = 6.0
    private let minimumLookAhead: TimeInterval = 0.18
    private let maximumLookAhead: TimeInterval = 0.6
    private let minimumDecodeInterval: TimeInterval = 1.0 / 240.0
    private let decodeIntervals = OSAllocatedUnfairLock<[UUID: TimeInterval]>(initialState: [:])

    func startPipeline(for clipID: UUID,
                       source: VideoSource,
                       timelineRange: ClosedRange<TimeInterval>,
                       frameDuration: TimeInterval) {
        pipelinesLock.withLock { storage in
            if storage[clipID] == nil {
                storage[clipID] = FrameRing()
            }
        }

        clipTimelineRanges.withLock { ranges in
            ranges[clipID] = timelineRange
        }

        decodeIntervals.withLock { intervals in
            // Match decode rate to video framerate for zero frame duplication
            let videoFPS = 1.0 / frameDuration
            intervals[clipID] = frameDuration
            print("[FramePipeline] Decode rate matched to video: \(String(format: "%.2f", videoFPS))fps (interval=\(String(format: "%.4f", frameDuration))s)")
        }

        decodeTasksLock.withLock { tasks in
            tasks[clipID]?.cancel()
            tasks[clipID] = Task { [weak self] in
                await self?.decodeLoop(clipID: clipID, source: source)
            }
        }
    }

    func stopPipeline(for clipID: UUID) {
        decodeTasksLock.withLock { tasks in
            tasks[clipID]?.cancel()
            tasks[clipID] = nil
        }
        pipelinesLock.withLock { storage in
            storage[clipID]?.clear()
            storage[clipID] = nil
        }
        clipTimelineRanges.withLock { ranges in
            ranges[clipID] = nil
        }
        decodeIntervals.withLock { intervals in
            intervals[clipID] = nil
        }
    }

    func stopAllPipelines() {
        decodeTasksLock.withLock { tasks in
            for (_, task) in tasks {
                task.cancel()
            }
            tasks.removeAll()
        }

        pipelinesLock.withLock { storage in
            for (_, ring) in storage {
                ring.clear()
            }
            storage.removeAll()
        }
        clipTimelineRanges.withLock { ranges in
            ranges.removeAll()
        }
        decodeIntervals.withLock { intervals in
            intervals.removeAll()
        }
    }

    /// Non-blocking frame retrieval for renderer with metadata
    func frameMetadata(for clipID: UUID, at time: TimeInterval) -> PipelineFrame? {
        let ring = pipelinesLock.withLock { $0[clipID] }
        return ring?.read(for: time)
    }

    func frameDuration(for clipID: UUID) -> TimeInterval? {
        decodeIntervals.withLock { $0[clipID] }
    }

    /// Backward compatibility helper for callers that only need the buffer
    func getFrame(for clipID: UUID, at time: TimeInterval) -> CVPixelBuffer? {
        guard let pixelBuffer = frameMetadata(for: clipID, at: time)?.pixelBuffer else {
            print("[PIPELINE_GET_FRAME] clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", time)) result=nil")
            return nil
        }
        
        // DIAGNOSTIC: Log pixel buffer details when retrieved for rendering
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        print("[PIPELINE_GET_FRAME] clip=\(clipID.uuidString.prefix(8)) time=\(String(format: "%.3f", time)) format=\(format) size=\(width)x\(height)")
        
        return pixelBuffer
    }

    private func decodeLoop(clipID: UUID, source: VideoSource) async {
        var lastDecodeTime: TimeInterval = -1

        while !Task.isCancelled {
            // Get current playback time from the authoritative PlaybackClock
            let currentTime = await MainActor.run { PlaybackClock.shared.currentTime() }

            // Monitor decode loop status
            await VideoPerformanceMonitor.shared.logDecodeLoop(clipID: clipID, currentTime: currentTime, bufferStatus: "active")

            guard let range = clipTimelineRanges.withLock({ $0[clipID] }) else {
                let decodeInterval = decodeIntervals.withLock { $0[clipID] ?? minimumDecodeInterval }
                let sleepNanoseconds = UInt64(decodeInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: max(sleepNanoseconds, 8_333_333))
                continue
            }
            guard range.upperBound > range.lowerBound else {
                let decodeInterval = decodeIntervals.withLock { $0[clipID] ?? minimumDecodeInterval }
                let sleepNanoseconds = UInt64(decodeInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: max(sleepNanoseconds, 8_333_333))
                continue
            }

            let decodeInterval = decodeIntervals.withLock { $0[clipID] ?? minimumDecodeInterval }
            let dynamicLookAhead = decodeInterval * lookAheadFrameFactor
            let lookAheadTime = min(max(dynamicLookAhead, minimumLookAhead), maximumLookAhead)
            
            // Decode multiple frames to fill the buffer ahead of playhead
            // Calculate how many frames we need to decode to stay ahead
            let framesNeeded = Int(ceil(lookAheadTime / decodeInterval))
            var decodedCount = 0
            
            for i in 0..<framesNeeded {
                let targetTime = currentTime + (Double(i) * decodeInterval)
                let clampedTarget = min(max(targetTime, range.lowerBound), range.upperBound)

                // Skip if we already decoded this frame recently (within same iteration)
                // CRITICAL FIX: Update lastDecodeTime BEFORE checking, so it works within the loop!
                if abs(clampedTarget - lastDecodeTime) < decodeInterval * 0.5 {
                    continue
                }

                do {
                    if let decodedFrame = try await source.copyFrame(at: clampedTarget, caller: "FramePipeline") {
                        let frame = PipelineFrame(
                            pixelBuffer: decodedFrame.pixelBuffer,
                            presentationTime: decodedFrame.timelineTime,
                            clipID: clipID
                        )
                        pipelinesLock.withLock { storage in
                            storage[clipID]?.write(frame)
                        }
                        await TransportController.shared.cacheFrame(frame.pixelBuffer,
                                                                     clipID: clipID,
                                                                     presentationTime: frame.presentationTime,
                                                                     origin: .playback,
                                                                     storeInPrimary: true)
                        // CRITICAL FIX: Update lastDecodeTime immediately after decode
                        // This prevents skipping frames within the same loop iteration
                        lastDecodeTime = frame.presentationTime
                        decodedCount += 1
                    }
                } catch {
                    print("[FramePipeline] Decode error for clip \(clipID): \(error)")
                }
            }

            // Sleep much shorter - just enough to avoid spinning
            // We want to check frequently if we need more frames
            let sleepDuration = UInt64(decodeInterval * 0.25 * 1_000_000_000) // Quarter frame interval
            try? await Task.sleep(nanoseconds: max(sleepDuration, 4_166_666))
        }
    }
}
