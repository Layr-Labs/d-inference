import DarkbloomFanProtocol
import Foundation
import Security

public struct FanPeerAuthorizationPolicy: Equatable, Sendable {
    public let configuredUID: UInt32
    public let configuredUserUUID: String

    public init(configuredUID: UInt32, configuredUserUUID: String) {
        self.configuredUID = configuredUID
        self.configuredUserUUID = configuredUserUUID
    }

    public func allows(
        effectiveUID: UInt32,
        currentUserUUID: String?,
        rootOnly: Bool = false
    ) -> Bool {
        if rootOnly {
            return effectiveUID == 0
        }
        if effectiveUID == 0 { return true }
        guard effectiveUID == configuredUID,
              let currentUserUUID,
              let current = UUID(uuidString: currentUserUUID),
              let configured = UUID(uuidString: configuredUserUUID)
        else {
            return false
        }
        return current == configured
    }
}

public enum FanCodeRequirements {
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else {
            return nil
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func requirement(identifier: String, teamID: String?) -> String {
        guard let teamID, !teamID.isEmpty else {
            // Local ad-hoc builds have no Team ID. NSXPCConnection still
            // validates the peer's signature and exact signing identifier.
            return "identifier \"\(identifier)\""
        }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public static var ownIdentityIsProduction: Bool {
        ownTeamID() == FanIPC.teamID
    }

    public static func providerRequirement() -> String {
        return requirement(
            identifier: FanIPC.providerIdentifier,
            teamID: FanIPC.teamID
        )
    }

    public static func helperRequirement() -> String {
        return requirement(
            identifier: FanIPC.helperIdentifier,
            teamID: FanIPC.teamID
        )
    }
}
