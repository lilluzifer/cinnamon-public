import Foundation
import Dispatch

/// Quality of Service Manager for optimal task prioritization on Apple Silicon
/// Implements Apple's QoS best practices for scrubbing and preview operations
final class QualityOfServiceManager: Sendable {

    // MARK: - Types

    enum WorkType {
        case userInteraction     // UI interaction (highest priority)
        case scrubbing          // Active scrubbing
        case playback           // Real-time playback
        case prefetch           // Frame prefetching
        case idleRender         // Background rendering
        case export             // Export operations
        case analysis           // GOP analysis, indexing

        var qos: DispatchQoS {
            switch self {
            case .userInteraction:
                return .userInteractive
            case .scrubbing:
                return .userInitiated
            case .playback:
                return .userInitiated
            case .prefetch:
                return .utility
            case .idleRender:
                return .background
            case .export:
                return .default
            case .analysis:
                return .utility
            }
        }

        var priority: TaskPriority {
            switch self {
            case .userInteraction:
                return .high
            case .scrubbing:
                return .userInitiated
            case .playback:
                return .userInitiated
            case .prefetch:
                return .utility
            case .idleRender:
                return .background
            case .export:
                return .medium
            case .analysis:
                return .utility
            }
        }

        var description: String {
            switch self {
            case .userInteraction:
                return "UserInteractive"
            case .scrubbing:
                return "Scrubbing"
            case .playback:
                return "Playback"
            case .prefetch:
                return "Prefetch"
            case .idleRender:
                return "IdleRender"
            case .export:
                return "Export"
            case .analysis:
                return "Analysis"
            }
        }
    }

    // MARK: - Queues

    private lazy var userInteractiveQueue = DispatchQueue(
        label: "com.cinnamon.qos.userInteractive",
        qos: .userInteractive,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem
    )

    private lazy var scrubQueue = DispatchQueue(
        label: "com.cinnamon.qos.scrub",
        qos: .userInitiated,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem,
        target: nil
    )

    private lazy var playbackQueue = DispatchQueue(
        label: "com.cinnamon.qos.playback",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    private lazy var prefetchQueue = DispatchQueue(
        label: "com.cinnamon.qos.prefetch",
        qos: .utility,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem
    )

    private lazy var idleQueue = DispatchQueue(
        label: "com.cinnamon.qos.idle",
        qos: .background,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem
    )

    private lazy var exportQueue = DispatchQueue(
        label: "com.cinnamon.qos.export",
        qos: .default,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    private lazy var analysisQueue = DispatchQueue(
        label: "com.cinnamon.qos.analysis",
        qos: .utility,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem
    )

    // MARK: - Singleton

    static let shared = QualityOfServiceManager()

    private init() {}

    // MARK: - Public Methods

    /// Get the appropriate queue for a work type
    func queue(for workType: WorkType) -> DispatchQueue {
        switch workType {
        case .userInteraction:
            return userInteractiveQueue
        case .scrubbing:
            return scrubQueue
        case .playback:
            return playbackQueue
        case .prefetch:
            return prefetchQueue
        case .idleRender:
            return idleQueue
        case .export:
            return exportQueue
        case .analysis:
            return analysisQueue
        }
    }

    /// Execute work with appropriate QoS
    func execute(workType: WorkType,
                 flags: DispatchWorkItemFlags = [],
                 work: @escaping @Sendable () -> Void) {
        let queue = self.queue(for: workType)
        queue.async(flags: flags, execute: work)
    }

    /// Execute async work with appropriate priority
    func executeAsync<T>(workType: WorkType,
                         work: @escaping () async throws -> T) -> Task<T, Error> {
        return Task(priority: workType.priority) {
            try await work()
        }
    }

    /// Create a task group with appropriate priority
    func createTaskGroup<T>(workType: WorkType,
                           body: @escaping (inout ThrowingTaskGroup<T, Error>) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Set task priority for the group by using the priority in Task creation
            try await body(&group)
        }
    }

    /// Adaptive work scheduling based on thermal state
    func scheduleAdaptive(workType: WorkType,
                         thermalAware: Bool = true,
                         work: @escaping () async -> Void) -> Task<Void, Never> {
        return Task(priority: workType.priority) {
            if thermalAware {
                await self.waitForThermalConditions(workType: workType)
            }
            await work()
        }
    }

    /// Wait for appropriate thermal conditions
    private func waitForThermalConditions(workType: WorkType) async {
        let info = ProcessInfo.processInfo

        // Check thermal state
        switch info.thermalState {
        case .nominal:
            // System is cool, proceed normally
            break
        case .fair:
            // Slight thermal pressure
            if workType == .idleRender || workType == .prefetch {
                // Delay background work slightly
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        case .serious:
            // Significant thermal pressure
            if workType == .idleRender || workType == .prefetch || workType == .analysis {
                // Delay non-critical work
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        case .critical:
            // Critical thermal state
            if workType != .userInteraction && workType != .scrubbing {
                // Only allow critical user-facing work
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            }
        @unknown default:
            break
        }
    }

    /// Concurrent work with optimal parallelism
    func performConcurrent<T>(workType: WorkType,
                             iterations: Int,
                             work: @escaping (Int) async throws -> T) async throws -> [T] {
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            // Limit concurrency based on work type and system resources
            let maxConcurrency = self.optimalConcurrency(for: workType)

            var currentTasks = 0

            for i in 0..<iterations {
                // Rate limit task creation
                if currentTasks >= maxConcurrency {
                    _ = try await group.next()
                    currentTasks -= 1
                }

                group.addTask(priority: workType.priority) {
                    let result = try await work(i)
                    return (i, result)
                }
                currentTasks += 1
            }

            // Collect results in order
            var results = [T?](repeating: nil, count: iterations)
            for try await (index, value) in group {
                results[index] = value
            }

            return results.compactMap { $0 }
        }
    }

    /// Calculate optimal concurrency based on work type
    private func optimalConcurrency(for workType: WorkType) -> Int {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount

        switch workType {
        case .userInteraction, .scrubbing:
            // High priority, use most cores
            return max(coreCount - 1, 1)
        case .playback:
            // Real-time, balanced approach
            return max(coreCount / 2, 1)
        case .prefetch:
            // Background prefetch, limited concurrency
            return max(coreCount / 4, 1)
        case .idleRender:
            // Lowest priority, minimal cores
            return 2
        case .export:
            // Export can use available cores
            return max(coreCount / 2, 1)
        case .analysis:
            // Analysis is background work
            return max(coreCount / 4, 1)
        }
    }

    /// Monitor and log QoS metrics
    func logMetrics() {
        let queues: [(String, DispatchQueue)] = [
            ("UserInteractive", userInteractiveQueue),
            ("Scrub", scrubQueue),
            ("Playback", playbackQueue),
            ("Prefetch", prefetchQueue),
            ("Idle", idleQueue),
            ("Export", exportQueue),
            ("Analysis", analysisQueue)
        ]

        for (name, queue) in queues {
            queue.async {
                let qos = DispatchQueue.currentQOS()
                print("[QoS] \(name) queue running at: \(qos.qosClass.description)")
            }
        }
    }
}

// MARK: - Extensions

extension DispatchQoS.QoSClass {
    var description: String {
        switch self {
        case .userInteractive:
            return "UserInteractive"
        case .userInitiated:
            return "UserInitiated"
        case .default:
            return "Default"
        case .utility:
            return "Utility"
        case .background:
            return "Background"
        case .unspecified:
            return "Unspecified"
        @unknown default:
            return "Unknown"
        }
    }
}

extension DispatchQueue {
    /// Get current QoS of the queue
    static func currentQOS() -> DispatchQoS {
        return DispatchQueue.global().sync {
            let currentClass = qos_class_self()
            let qosClass: DispatchQoS.QoSClass = {
                switch currentClass {
                case QOS_CLASS_USER_INTERACTIVE:
                    return .userInteractive
                case QOS_CLASS_USER_INITIATED:
                    return .userInitiated
                case QOS_CLASS_DEFAULT:
                    return .default
                case QOS_CLASS_UTILITY:
                    return .utility
                case QOS_CLASS_BACKGROUND:
                    return .background
                default:
                    return .unspecified
                }
            }()
            return DispatchQoS(qosClass: qosClass, relativePriority: 0)
        }
    }
}