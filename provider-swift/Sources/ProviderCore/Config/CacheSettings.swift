import Foundation

/// Persistent operator choices for encrypted inference caches, separate from
/// downloaded model weights. Nil fields preserve the compiled defaults.
public struct CacheSettings: Codable, Equatable, Sendable {
    public var directory: String?
    public var volumeUUID: String?
    public var dailyWriteGB: Double?

    public init(directory: String? = nil, volumeUUID: String? = nil, dailyWriteGB: Double? = nil) {
        self.directory = directory
        self.volumeUUID = volumeUUID
        self.dailyWriteGB = dailyWriteGB
    }

    enum CodingKeys: String, CodingKey {
        case directory
        case volumeUUID = "volume_uuid"
        case dailyWriteGB = "daily_write_gb"
    }

    public func validate() throws {
        if let value = dailyWriteGB {
            guard value.isFinite, value >= 0, value < Double(Int.max) / 1_000_000_000,
                  value == 0 || value * 1_000_000_000 >= 1 else {
                throw ConfigError.parseFailed(detail: "cache.daily_write_gb must be 0 (unlimited) or a positive, representable number of decimal GB")
            }
        }
        guard (directory == nil) == (volumeUUID == nil) else {
            throw ConfigError.parseFailed(detail: "cache.directory and cache.volume_uuid must be set together using darkbloom cache set --directory")
        }
        if let directory, let volumeUUID {
            guard directory.hasPrefix("/"), !directory.utf8.contains(0),
                  !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  UUID(uuidString: volumeUUID) != nil else {
                throw ConfigError.parseFailed(detail: "invalid cache directory or volume UUID; use darkbloom cache set --directory")
            }
        }
    }
}
