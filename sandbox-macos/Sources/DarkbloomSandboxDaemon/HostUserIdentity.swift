import Foundation
import CoreFoundation

enum HostUserIdentityError: Error, Equatable, CustomStringConvertible {
    case invalidBinding
    case insecureFile
    case identityMismatch
    case lookupUnavailable(Int32)

    var description: String {
        switch self {
        case .invalidBinding: "host user identity binding is missing or invalid"
        case .insecureFile: "host user identity file is not a stable protected root-owned file"
        case .identityMismatch: "current host process does not match the selected user identity"
        case .lookupUnavailable(let code): "host user identity lookup unavailable (code \(code))"
        }
    }
}

struct HostUserIdentity: Codable, Equatable, Sendable {
    let recordName: String
    let uid: UInt32
    let primaryGID: UInt32
    let generatedUID: String
    let homeDirectory: String

    func validate() throws {
        guard recordName.range(of: "^[A-Za-z][A-Za-z0-9._-]{0,63}$", options: .regularExpression)
                == recordName.startIndex..<recordName.endIndex,
              uid >= 501, uid != 2001, uid != UInt32.max, primaryGID > 0, primaryGID != UInt32.max,
              let uuid = UUID(uuidString: generatedUID), uuid.uuidString == generatedUID,
              uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              !generatedUID.hasPrefix("FFFFEEEE-DDDD-CCCC-BBBB-AAAA"),
              !generatedUID.hasPrefix("AAAABBBB-CCCC-DDDD-EEEE-FFFF"),
              homeDirectory.utf8.count <= 1024, homeDirectory.hasPrefix("/"), homeDirectory != "/",
              !["/var/empty", "/private/var/empty"].contains(homeDirectory),
              !homeDirectory.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !homeDirectory.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw HostUserIdentityError.invalidBinding }
    }
}

struct HostUserIdentityBinding: Decodable, Equatable, Sendable {
    let schema_version: UInt32
    let host_id: String
    let host_user: HostUserIdentity

    static func decode(_ data: Data, hostID: UUID) throws -> Self {
        do {
            // Reject unknown fields and bool-as-integer coercion before the
            // typed decoder. Password/authentication data never belong here.
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == ["schema_version", "host_id", "host_user"],
                  let user = root["host_user"] as? [String: Any],
                  Set(user.keys) == ["recordName", "uid", "primaryGID", "generatedUID", "homeDirectory"],
                  isInteger(root["schema_version"]), isInteger(user["uid"]), isInteger(user["primaryGID"])
            else { throw HostUserIdentityError.invalidBinding }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.schema_version == 1, value.host_id == hostID.uuidString.lowercased() else {
                throw HostUserIdentityError.invalidBinding
            }
            try value.host_user.validate()
            return value
        } catch { throw HostUserIdentityError.invalidBinding }
    }

    private static func isInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !["f", "d"].contains(String(cString: number.objCType))
    }
}
