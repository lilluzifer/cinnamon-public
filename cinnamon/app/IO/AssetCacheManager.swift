import Foundation
import CryptoKit

/// Resolves asset URLs to local file URLs, downloading remote media to a
/// persistent cache directory so audio/video decoders can operate on files.
actor AssetCacheManager {
    static let shared = AssetCacheManager()

    private let cacheDirectory: URL
    private let manifestURL: URL
    private var inFlightTasks: [URL: Task<URL, Error>] = [:]
    private var manifest: [String: CacheRecord] = [:]
    private let fileManager = FileManager.default
    private let maxCacheSize: Int64 = 5 * 1024 * 1024 * 1024 // 5 GB

    nonisolated static func cacheRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("cinnamon", isDirectory: true)
            .appendingPathComponent("AssetCache", isDirectory: true)
    }

    nonisolated static func cachedFileURL(for originalURL: URL) -> URL {
        if originalURL.isFileURL {
            return originalURL
        }
        let dir = cacheRootDirectory()
        let ext = originalURL.pathExtension.isEmpty ? "dat" : originalURL.pathExtension
        let hash = sha1(originalURL.absoluteString)
        let filename = "\(hash).\(ext)"
        return dir.appendingPathComponent(filename)
    }

    init() {
        let dir = Self.cacheRootDirectory()
        cacheDirectory = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        manifestURL = dir.appendingPathComponent("manifest.json")
        loadManifest()
    }

    func resolve(originalURL: URL) async throws -> URL {
        if originalURL.isFileURL {
            return originalURL
        }

        if let cached = cachedFile(for: originalURL) {
            updateLastAccess(for: originalURL)
            return cached
        }

        if let task = inFlightTasks[originalURL] {
            return try await task.value
        }

        let task = Task { () throws -> URL in
            let destination = destinationURL(for: originalURL)
            if fileManager.fileExists(atPath: destination.path) {
                updateManifest(for: originalURL, path: destination)
                saveManifest()
                return destination
            }

            do {
                let (tempURL, response) = try await URLSession.shared.download(from: originalURL)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "AssetCacheManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(originalURL)"])
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: tempURL, to: destination)
                updateManifest(for: originalURL, path: destination)
                try evictIfNeeded()
                saveManifest()
                return destination
            } catch {
                throw NSError(domain: "AssetCacheManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "Failed caching \(originalURL): \(error.localizedDescription)"])
            }
        }

        inFlightTasks[originalURL] = task
        defer { inFlightTasks[originalURL] = nil }
        return try await task.value
    }

    func prefetch(urls: [URL]) {
        Task {
            for url in urls {
                do {
                    _ = try await resolve(originalURL: url)
                } catch {
                    print("[AssetCache] Prefetch failed for \(url): \(error)")
                }
            }
        }
    }

    private func cachedFile(for originalURL: URL) -> URL? {
        let path = destinationURL(for: originalURL)
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    private func destinationURL(for originalURL: URL) -> URL {
        let ext = originalURL.pathExtension.isEmpty ? "dat" : originalURL.pathExtension
        let hash = Self.sha1(originalURL.absoluteString)
        let filename = "\(hash).\(ext)"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private static func sha1(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadManifest() {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode([String: CacheRecord].self, from: data)
        } catch {
            print("[AssetCache] Failed to load manifest: \(error)")
        }
    }

    private func saveManifest() {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            print("[AssetCache] Failed to save manifest: \(error)")
        }
    }

    private func updateManifest(for originalURL: URL, path: URL) {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let record = CacheRecord(filename: path.lastPathComponent,
                                     originalURL: originalURL.absoluteString,
                                     size: size,
                                     lastAccess: Date())
            manifest[originalURL.absoluteString] = record
        } catch {
            print("[AssetCache] Could not inspect file \(path): \(error)")
        }
    }

    private func updateLastAccess(for originalURL: URL) {
        let key = originalURL.absoluteString
        guard var record = manifest[key] else { return }
        record.lastAccess = Date()
        manifest[key] = record
        saveManifest()
    }

    private func evictIfNeeded() throws {
        var total: Int64 = manifest.values.reduce(0) { $0 + $1.size }
        guard total > maxCacheSize else { return }
        let sorted = manifest.values.sorted { $0.lastAccess < $1.lastAccess }
        for record in sorted {
            if total <= maxCacheSize { break }
            let path = cacheDirectory.appendingPathComponent(record.filename)
            do {
                try fileManager.removeItem(at: path)
                manifest.removeValue(forKey: record.originalURL)
                total -= record.size
            } catch {
                print("[AssetCache] Failed to evict \(path): \(error)")
            }
        }
        saveManifest()
    }

    private struct CacheRecord: Codable {
        var filename: String
        var originalURL: String
        var size: Int64
        var lastAccess: Date
    }
}
