import Foundation

/// A parsed BSD disk identifier from system inventory, never a caller path.
struct AccountlessDiskIdentifier: Hashable, Codable, Sendable {
    let rawValue: String
    var nodePath: String { "/dev/" + rawValue }
    var isWholeDisk: Bool { !rawValue.dropFirst(4).contains("s") }

    init(_ value: String) throws {
        guard value.utf8.count <= 64, value.hasPrefix("disk") else { throw AccountlessDiskError.invalidInventory }
        let components = value.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 4,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw AccountlessDiskError.invalidInventory
        }
        rawValue = value
    }

    func isDirectPartition(of parent: Self) -> Bool {
        guard parent.isWholeDisk, rawValue.hasPrefix(parent.rawValue + "s") else { return false }
        let suffix = rawValue.dropFirst(parent.rawValue.count + 1)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }

    init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

enum AccountlessDiskError: Error, Equatable {
    case invalidInventory
    case unexpectedMount
    case bindingChanged
    case commandFailed
    case unsafeMountpoint
}
