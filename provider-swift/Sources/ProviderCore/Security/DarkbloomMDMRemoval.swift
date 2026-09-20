import Foundation

/// Identifies the installed enrollment that the operator may remove in Apple
/// Settings. No command in this type removes profiles or deletes local keys.
public struct DarkbloomMDMRemovalTarget: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let serverURL: String
}

public enum DarkbloomMDMRemoval {
    public static let profileIdentifier = "io.darkbloom.enroll"
    public static let mdmPayloadIdentifier = "io.darkbloom.enroll.mdm"

    /// `profiles show -type configuration -output stdout-xml` reports profiles
    /// grouped by user / _computerlevel. Match exact identifiers AND the MDM
    /// endpoint; a name, domain suffix or embedded provisioning profile cannot
    /// select a removal target. Refuse ambiguous duplicate enrollments.
    public static func target(in data: Data, coordinatorURL: String) -> DarkbloomMDMRemovalTarget? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let expected = URLComponents(string: coordinatorHTTPBase(coordinatorURL)),
              expected.scheme == "https", let host = expected.host?.lowercased()
        else { return nil }
        let basePath = expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let expectedPath = basePath.isEmpty ? "/mdm/connect" : "/\(basePath)/mdm/connect"
        let profiles = dictionaries(in: root).filter {
            ($0["PayloadIdentifier"] as? String ?? $0["ProfileIdentifier"] as? String) == profileIdentifier
        }
        guard profiles.count == 1, let profile = profiles.first else { return nil }
        let payloads = dictionaries(in: profile["PayloadContent"] ?? profile["ProfileItems"] ?? [])
        let mdm = payloads.filter { ($0["PayloadType"] as? String) == "com.apple.mdm" }
        guard mdm.count == 1, let payload = mdm.first,
              payload["PayloadIdentifier"] as? String == mdmPayloadIdentifier else { return nil }
        // `profiles show` wraps settings in PayloadContent; the original
        // .mobileconfig puts them next to the payload's identity fields.
        let settings = payload["PayloadContent"] as? [String: Any] ?? payload
        guard let server = settings["ServerURL"] as? String,
              let endpoint = URLComponents(string: server),
              endpoint.scheme == "https", endpoint.host?.lowercased() == host,
              (endpoint.port ?? 443) == (expected.port ?? 443),
              endpoint.path == expectedPath
        else { return nil }
        guard endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { return nil }
        return DarkbloomMDMRemovalTarget(
            identifier: profileIdentifier,
            displayName: profile["PayloadDisplayName"] as? String
                ?? profile["ProfileDisplayName"] as? String ?? "Darkbloom Provider Enrollment",
            serverURL: server)
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dict = value as? [String: Any] {
            return [dict] + dict.values.flatMap { dictionaries(in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { dictionaries(in: $0) } }
        return []
    }

    /// Read-only inventory. A command or parse failure withholds removal
    /// guidance instead of guessing from the enrollment server's domain.
    public static func installedTarget(
        coordinatorURL: String,
        allowAdministratorPrompt: Bool = false,
        beforeAdministratorPrompt: (() -> Void)? = nil
    ) -> DarkbloomMDMRemovalTarget? {
        let arguments = ["show", "-type", "configuration", "-output", "stdout-xml"]
        if let data = readProfiles(executable: "/usr/bin/profiles", arguments: arguments),
           let target = target(in: data, coordinatorURL: coordinatorURL) { return target }
        // Device-level configuration may not appear in the unprivileged
        // user's inventory. Elevate only this fixed read command after an
        // explicit interactive migration action, never the provider process.
        guard allowAdministratorPrompt else { return nil }
        beforeAdministratorPrompt?()
        guard let data = readProfiles(executable: "/usr/bin/sudo",
                                      arguments: ["--", "/usr/bin/profiles"] + arguments + ["-all"],
                                      showErrors: true) else { return nil }
        return target(in: data, coordinatorURL: coordinatorURL)
    }

    private static func readProfiles(executable: String, arguments: [String], showErrors: Bool = false) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = showErrors ? FileHandle.standardError : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
