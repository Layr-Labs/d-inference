import Foundation
import ProviderAppAttest

/// Receipt/reply timestamps for APNs code-identity pushes, persisted in
/// `apns-push-history.json` beside the daemon state file (0600) so the next
/// connection or process reports what happened to earlier pushes. Holds no
/// device token, nonce or payload.
public struct APNsPushHistory: Codable, Sendable, Equatable {
    public static let cap = 50
    public static let window: TimeInterval = 86_400

    public var receivedAt: [Double]
    public var repliedAt: [Double]
    /// Whether the serving process held an APNs device token when it last
    /// checked (registration, or a late token). A bool, never the token, so
    /// `darkbloom doctor` can tell a failed APNs registration apart.
    public var deviceTokenPresent: Bool?
    public var deviceTokenCheckedAt: Double?

    public init(receivedAt: [Double] = [], repliedAt: [Double] = [],
                deviceTokenPresent: Bool? = nil, deviceTokenCheckedAt: Double? = nil) {
        self.receivedAt = receivedAt
        self.repliedAt = repliedAt
        self.deviceTokenPresent = deviceTokenPresent
        self.deviceTokenCheckedAt = deviceTokenCheckedAt
    }

    enum CodingKeys: String, CodingKey {
        case receivedAt = "received_at"
        case repliedAt = "replied_at"
        case deviceTokenPresent = "device_token_present"
        case deviceTokenCheckedAt = "device_token_checked_at"
    }

    public mutating func recordReceipt(at date: Date) {
        receivedAt = Self.appending(date.timeIntervalSince1970, to: receivedAt)
    }

    public mutating func recordReply(at date: Date) {
        repliedAt = Self.appending(date.timeIntervalSince1970, to: repliedAt)
    }

    private static func appending(_ value: Double, to list: [Double]) -> [Double] {
        Array((list + [value]).suffix(cap))
    }

    /// Wire summary. Ages are omitted without a timestamp or when it lies in
    /// the future (clock stepped backwards).
    public func summary(deviceTokenPresent: Bool?, now: Date) -> AppAttestPushHistory {
        let current = now.timeIntervalSince1970
        func age(_ latest: Double?) -> Int? {
            guard let latest, latest.isFinite, latest <= current, current - latest < Double(Int32.max) else { return nil }
            return Int(current - latest)
        }
        let recent = receivedAt.filter { $0.isFinite && $0 <= current && current - $0 < Self.window }.count
        return AppAttestPushHistory(
            deviceTokenPresent: deviceTokenPresent,
            pushesReceivedLast24h: min(AppAttestPushHistory.maxPushes, recent),
            lastPushReceivedAgeSeconds: age(receivedAt.max()),
            lastReplySentAgeSeconds: age(repliedAt.max()))
    }
}

/// Serialized read-modify-write of the push history file. Unreadable or
/// corrupt content starts a fresh history; write failures are swallowed
/// because diagnostics must never affect attestation.
public final class APNsPushHistoryStore: @unchecked Sendable {
    public static let fileName = "apns-push-history.json"

    public let url: URL
    /// Process-wide: every store instance (the push handler's and the reply
    /// path's) serializes its read-modify-write through this one lock.
    private static let lock = NSLock()

    /// `directory` is the daemon state file's directory.
    public init(directory: URL = DaemonStateFile.path().deletingLastPathComponent()) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func load() -> APNsPushHistory {
        Self.lock.withLock { unlockedLoad() }
    }

    public func recordReceipt(at date: Date = Date()) {
        update { $0.recordReceipt(at: date) }
    }

    public func recordReply(at date: Date = Date()) {
        update { $0.recordReply(at: date) }
    }

    public func recordDeviceToken(present: Bool, at date: Date = Date()) {
        update {
            $0.deviceTokenPresent = present
            $0.deviceTokenCheckedAt = date.timeIntervalSince1970
        }
    }

    private func update(_ change: (inout APNsPushHistory) -> Void) {
        Self.lock.withLock {
            var history = unlockedLoad()
            change(&history)
            if let data = try? JSONEncoder().encode(history) { try? OwnerOnlyFile.write(data, to: url) }
        }
    }

    private func unlockedLoad() -> APNsPushHistory {
        guard let data = OwnerOnlyFile.read(url),
              var history = try? JSONDecoder().decode(APNsPushHistory.self, from: data) else { return APNsPushHistory() }
        history.receivedAt = Array(history.receivedAt.suffix(APNsPushHistory.cap))
        history.repliedAt = Array(history.repliedAt.suffix(APNsPushHistory.cap))
        return history
    }
}
