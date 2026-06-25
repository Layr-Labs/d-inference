import CryptoKit
import Foundation

public struct AdaptivePrefillStoreKey: Sendable, Hashable {
    public let modelId: String
    public let weightIdentity: String
    public let kvMode: String
    public let hardwareMemoryFingerprint: String

    public init(
        modelId: String,
        weightIdentity: String,
        kvMode: String,
        hardwareMemoryFingerprint: String
    ) {
        self.modelId = modelId
        self.weightIdentity = weightIdentity
        self.kvMode = kvMode
        self.hardwareMemoryFingerprint = hardwareMemoryFingerprint
    }

    var storageKey: String {
        let raw = [
            modelId,
            weightIdentity,
            kvMode,
            hardwareMemoryFingerprint,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public final class AdaptivePrefillStore: @unchecked Sendable {
    private struct PersistedFile: Codable {
        var version: Int
        var states: [String: AdaptivePrefillState]
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL = AdaptivePrefillStore.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("darkbloom", isDirectory: true)
            .appendingPathComponent("adaptive-prefill.json")
    }

    public func load(key: AdaptivePrefillStoreKey) -> AdaptivePrefillState? {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked().states[key.storageKey]
    }

    public func save(_ state: AdaptivePrefillState, key: AdaptivePrefillStoreKey) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = readUnlocked()
        file.states[key.storageKey] = state
        try writeUnlocked(file)
    }

    private func readUnlocked() -> PersistedFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data),
              file.version == 1
        else {
            return PersistedFile(version: 1, states: [:])
        }
        return file
    }

    private func writeUnlocked(_ file: PersistedFile) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: [.atomic])
    }
}
