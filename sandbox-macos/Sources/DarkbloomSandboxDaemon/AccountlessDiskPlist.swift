import CoreFoundation
import Foundation

enum AccountlessDiskPlist {
    static func root(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 4 * 1_048_576,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AccountlessDiskError.invalidInventory
        }
        return root
    }

    static func records(_ value: Any?, maximum: Int = 128) throws -> [[String: Any]] {
        guard let values = value as? [[String: Any]], !values.isEmpty, values.count <= maximum else {
            throw AccountlessDiskError.invalidInventory
        }
        return values
    }

    static func disk(_ value: Any?) throws -> AccountlessDiskIdentifier {
        guard let value = value as? String else { throw AccountlessDiskError.invalidInventory }
        return try .init(value)
    }

    static func uuid(_ value: Any?) throws -> UUID {
        guard let string = value as? String, let value = UUID(uuidString: string),
              value.uuidString != "00000000-0000-0000-0000-000000000000" else { throw AccountlessDiskError.invalidInventory }
        return value
    }

    static func boolean(_ value: Any?) throws -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw AccountlessDiskError.invalidInventory
        }
        return value.boolValue
    }

    static func requireUnmounted(_ value: [String: Any]) throws {
        guard let mount = value["MountPoint"] else { return }
        guard let mount = mount as? String else { throw AccountlessDiskError.invalidInventory }
        guard mount.isEmpty else { throw AccountlessDiskError.unexpectedMount }
    }
}
