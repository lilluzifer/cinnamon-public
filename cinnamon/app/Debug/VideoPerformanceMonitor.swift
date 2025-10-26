import Foundation
import QuartzCore

/// Real-time performance monitoring for video pipeline debugging
@MainActor
final class VideoPerformanceMonitor {
    static let shared = VideoPerformanceMonitor()

    private var isEnabled = true
    private var frameRequestTimes: [UUID: CFAbsoluteTime] = [:]
    private var frameDeliveryTimes: [UUID: CFAbsoluteTime] = [:]
    private var readerCreationTimes: [UUID: CFAbsoluteTime] = [:]

    private var lastLogTime: CFAbsoluteTime = 0
    private var frameCount = 0
    private var totalFrameTime: CFAbsoluteTime = 0

    private init() {}

    // MARK: - Frame Request Monitoring

    func logFrameRequest(clipID: UUID, time: TimeInterval) {
        guard isEnabled else { return }
        frameRequestTimes[clipID] = CFAbsoluteTimeGetCurrent()

        // Log every 60 frames or every 2 seconds
        let now = CFAbsoluteTimeGetCurrent()
        if frameCount % 60 == 0 || now - lastLogTime > 2.0 {
            print("🎬 [VideoMonitor] Frame requested for clip \(clipID.uuidString.prefix(8)) at time \(String(format: "%.3f", time))s")
            lastLogTime = now
        }
        frameCount += 1
    }

    func logFrameDelivered(clipID: UUID, success: Bool) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        frameDeliveryTimes[clipID] = now

        if let requestTime = frameRequestTimes[clipID] {
            let deliveryTime = now - requestTime
            totalFrameTime += deliveryTime

            let status = success ? "✅" : "❌"
            let timeMs = deliveryTime * 1000

            if deliveryTime > 0.1 { // Log slow frames (>100ms)
                print("🐌 [VideoMonitor] \(status) SLOW FRAME \(clipID.uuidString.prefix(8)): \(String(format: "%.1f", timeMs))ms")
            } else if frameCount % 30 == 0 {
                let avgMs = (totalFrameTime / Double(frameCount)) * 1000
                print("📊 [VideoMonitor] \(status) Frame \(frameCount): \(String(format: "%.1f", timeMs))ms (avg: \(String(format: "%.1f", avgMs))ms)")
            }

            frameRequestTimes[clipID] = nil
        }
    }

    // MARK: - AVAssetReader Monitoring

    func logReaderCreation(clipID: UUID, startTime: TimeInterval) {
        guard isEnabled else { return }
        readerCreationTimes[clipID] = CFAbsoluteTimeGetCurrent()
        print("🔧 [VideoMonitor] Creating AVAssetReader for clip \(clipID.uuidString.prefix(8)) at \(String(format: "%.3f", startTime))s")
    }

    func logReaderReady(clipID: UUID, success: Bool) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if let creationTime = readerCreationTimes[clipID] {
            let creationDuration = now - creationTime
            let status = success ? "✅" : "❌"
            let timeMs = creationDuration * 1000

            if creationDuration > 0.5 { // Log slow reader creation (>500ms)
                print("🚨 [VideoMonitor] \(status) SLOW READER CREATION \(clipID.uuidString.prefix(8)): \(String(format: "%.1f", timeMs))ms")
            } else {
                print("⚡ [VideoMonitor] \(status) Reader ready \(clipID.uuidString.prefix(8)): \(String(format: "%.1f", timeMs))ms")
            }

            readerCreationTimes[clipID] = nil
        }
    }

    // MARK: - FramePipeline Monitoring

    func logDecodeLoop(clipID: UUID, currentTime: TimeInterval, bufferStatus: String) {
        guard isEnabled else { return }
        if frameCount % 120 == 0 { // Log every 120 frames (every ~2 seconds at 60fps)
            print("🔄 [VideoMonitor] DecodeLoop clip \(clipID.uuidString.prefix(8)): time=\(String(format: "%.3f", currentTime))s, buffer=\(bufferStatus)")
        }
    }

    func logFrameBufferEvent(clipID: UUID, event: String, details: String = "") {
        guard isEnabled else { return }
        print("💾 [VideoMonitor] Buffer[\(clipID.uuidString.prefix(8))]: \(event) \(details)")
    }

    // MARK: - Performance Alerts

    func checkPerformanceIssues() {
        guard isEnabled && frameCount > 0 else { return }

        let avgFrameTime = totalFrameTime / Double(frameCount)

        if avgFrameTime > 0.05 { // Average frame time > 50ms
            print("⚠️ [VideoMonitor] PERFORMANCE ALERT: Average frame time \(String(format: "%.1f", avgFrameTime * 1000))ms (should be <50ms)")
        }

        if frameCount > 300 { // Reset counters every 5 minutes at 60fps
            frameCount = 0
            totalFrameTime = 0
        }
    }

    // MARK: - System Resource Monitoring

    func logSystemResources() {
        let processInfo = ProcessInfo.processInfo
        let physicalMemory = Double(processInfo.physicalMemory) / 1024 / 1024 / 1024 // GB

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
            print("💻 [VideoMonitor] System: \(String(format: "%.1f", usedMemoryMB))MB used / \(String(format: "%.1f", physicalMemory))GB total")
        }
    }

    // MARK: - Control

    func enable() {
        isEnabled = true
        print("🔍 [VideoMonitor] Performance monitoring ENABLED")
    }

    func disable() {
        isEnabled = false
        print("🔇 [VideoMonitor] Performance monitoring DISABLED")
    }
}