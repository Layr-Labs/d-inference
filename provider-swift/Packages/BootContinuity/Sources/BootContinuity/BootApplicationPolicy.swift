import Foundation

struct BootApplicationPolicy {
    static let identifier = "io.darkbloom.provider"
    static let teamID = "SLDQ2GJ6TL"
    static let applicationID = "\(teamID).\(identifier)"
    static let forbiddenEntitlements = [
        "get-task-allow", "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.allow-jit",
    ]

    static func validate(identifier: String, teamID: String, hardenedRuntime: Bool,
                         entitlements: [String: Any], executable: URL, bundle: URL,
                         bundleExecutable: URL?) throws {
        guard identifier == Self.identifier, teamID == Self.teamID, hardenedRuntime,
              entitlements["com.apple.application-identifier"] as? String == applicationID,
              let groups = entitlements["keychain-access-groups"] as? [String],
              groups.contains(DataProtectionBootIdentityStore.accessGroup),
              bundle.pathExtension == "app",
              executable.resolvingSymlinksInPath() == bundleExecutable?.resolvingSymlinksInPath(),
              executable.resolvingSymlinksInPath() == bundle.appendingPathComponent("Contents/MacOS/darkbloom").resolvingSymlinksInPath()
        else { throw BootCustodyError.applicationNotPermitted }
        for name in forbiddenEntitlements {
            // Entitlement presence with any unexpected shape is rejected too.
            if let value = entitlements[name] {
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
                      (value as? Bool) == false else {
                    throw BootCustodyError.applicationNotPermitted
                }
            }
        }
    }
}
