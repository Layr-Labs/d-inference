import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Usage metadata only: never prompts, output text, credentials, or request bodies.
public struct ProviderUsageRecord: Codable, Sendable, Equatable {
    public let id: String
    public let sessionStartedAt: Double
    public let completedAt: Double
    public let model: String
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let cachedInputTokens: UInt64?
    public let reasoningTokens: UInt64?
    public let exact: Bool

    public init(id: String, sessionStartedAt: Double, completedAt: Double = Date().timeIntervalSince1970,
                model: String, inputTokens: UInt64, outputTokens: UInt64,
                cachedInputTokens: UInt64?, reasoningTokens: UInt64?, exact: Bool) {
        self.id = id; self.sessionStartedAt = sessionStartedAt; self.completedAt = completedAt
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens.map { min($0, inputTokens) }
        self.reasoningTokens = reasoningTokens.map { min($0, outputTokens) }; self.exact = exact
    }
}

/// A bounded, owner-only journal shared by the provider and desktop reader.
/// Atomic replacement keeps readers from observing half of a terminal record.
public final class ProviderUsageHistory: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".darkbloom/usage-history.json")
    }
    private let queue = DispatchQueue(label: "dev.darkbloom.usage-history")
    private let lock = NSLock()
    private let url: URL
    private var records: [ProviderUsageRecord]
    public init(url: URL = defaultURL) {
        self.url = url; records = Self.read(url: url)
    }
    public static func read(url: URL = defaultURL) -> [ProviderUsageRecord] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let data = try? Data(contentsOf: url), data.count <= 4_000_000 else { return [] }
        return (try? JSONDecoder().decode([ProviderUsageRecord].self, from: data)) ?? []
    }
    /// Terminal responses never wait on journal disk I/O.
    public func enqueue(_ record: ProviderUsageRecord) {
        queue.async { [self] in
            do { try self.record(record) }
            catch { ProviderLogger(subsystem: "dev.darkbloom.provider", category: "usage").warning("Local usage history could not be saved") }
        }
    }
    @discardableResult public func record(_ record: ProviderUsageRecord) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !records.contains(where: { $0.id == record.id && $0.sessionStartedAt == record.sessionStartedAt }) else { return false }
        let next = Array((records + [record]).suffix(4096))
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        let temporary = directory.appendingPathComponent(".usage-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(next)); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        records = next
        return true
    }
}
