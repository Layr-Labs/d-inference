import Foundation

/// When a stalled DeviceCheck operation may trigger a graceful provider
/// restart. Only a new process releases the stranded Apple admission.
public enum AppAttestStallRestartPolicy {
    /// At most one automatic restart per interval, across process restarts.
    public static let minimumInterval: TimeInterval = 6 * 3600

    public enum SkipReason: String, Sendable, Equatable {
        case notStalled = "not_stalled"
        case recentlyRestarted = "recently_restarted"
        case lifecycleBusy = "lifecycle_busy"
        case inferenceActive = "inference_active"
    }

    public enum Decision: Sendable, Equatable {
        case restart
        case skip(SkipReason)
    }

    /// A marker from the future (clock moved backwards) also counts as recent
    /// unless it is more than one interval away.
    public static func decide(stalledSeconds: Int?, inferenceActive: Bool, lifecycleBusy: Bool,
                              lastRestartAt: Date?, now: Date) -> Decision {
        guard let stalledSeconds, Double(stalledSeconds) > AppleOperationStall.threshold else {
            return .skip(.notStalled)
        }
        if let lastRestartAt, abs(now.timeIntervalSince(lastRestartAt)) < minimumInterval {
            return .skip(.recentlyRestarted)
        }
        if lifecycleBusy { return .skip(.lifecycleBusy) }
        if inferenceActive { return .skip(.inferenceActive) }
        return .restart
    }
}

/// Persisted time of the last automatic stall restart. Written before the
/// restart is issued so a failed or looping restart cannot exceed the limit.
public struct AppAttestStallRestartMarker: Sendable {
    public static let fileName = "app-attest-stall-restart.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    private struct Record: Codable {
        let restartedAt: Double
        enum CodingKeys: String, CodingKey { case restartedAt = "restarted_at" }
    }

    /// An unreadable marker falls back to its modification time, so damage
    /// cannot lift the limit early.
    public func lastRestart() -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(Record.self, from: data), record.restartedAt.isFinite {
            return Date(timeIntervalSince1970: record.restartedAt)
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func record(_ date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(restartedAt: date.timeIntervalSince1970))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
