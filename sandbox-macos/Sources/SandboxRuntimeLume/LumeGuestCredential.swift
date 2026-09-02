import Foundation

/// The per-sandbox guest accounts created by Lume patch 0006.
///
/// Lume's stock unattended install produces one administrator with the fixed
/// credential `lume`/`lume`, shared by every guest on every host. That account
/// can rewrite its own launchd metadata and SSH startup files, so a tenant
/// command running as it could tamper with the control path supervising it.
///
/// A sandbox therefore gets its own randomly generated administrator plus a
/// separate unprivileged account that tenant work runs as.
package struct LumeGuestCredential: Codable, Equatable, Sendable {
    /// Administrator used for bootstrap and for `lume ssh`.
    package let bootstrapUsername: String
    package let bootstrapPassword: String

    /// Unprivileged account tenant work runs as. No groups, no login
    /// credential, never the autologin user.
    package let tenantUsername: String
    package let tenantUID: String

    package var bootstrapHome: String { "/Users/\(bootstrapUsername)" }
    package var tenantHome: String { "/Users/\(tenantUsername)" }

    package init(
        bootstrapUsername: String,
        bootstrapPassword: String,
        tenantUsername: String,
        tenantUID: String
    ) {
        self.bootstrapUsername = bootstrapUsername
        self.bootstrapPassword = bootstrapPassword
        self.tenantUsername = tenantUsername
        self.tenantUID = tenantUID
    }

    /// What a guest created before per-sandbox credentials looks like.
    ///
    /// Records written by an older daemon carry no credential, and a VM
    /// installed from them really does have `lume`/`lume`, so this is the
    /// correct reading of their absence rather than a placeholder.
    package static let legacy = LumeGuestCredential(
        bootstrapUsername: "lume",
        bootstrapPassword: "lume",
        tenantUsername: "lume",
        tenantUID: "501"
    )

    /// True when this is the shared credential rather than a per-sandbox one.
    /// Tenant execution must never be enabled against it.
    package var isLegacyShared: Bool { self == Self.legacy }

    /// Read by patched `lume create` and `lume ssh`.
    package static let passwordEnvironmentVariable = "LUME_BOOTSTRAP_PASSWORD"

    package static let tenantAccountName = "sandbox"
    package static let tenantAccountUID = "502"
    /// Enough entropy that the credential is not guessable from the guest.
    package static let generatedPasswordBytes = 24

    /// Mints a fresh administrator credential for one sandbox.
    package static func generate() -> LumeGuestCredential {
        LumeGuestCredential(
            // A distinct account name as well as a distinct password, so a
            // guest cannot assume the administrator is called `lume`.
            bootstrapUsername: "db-\(randomToken(bytes: 6))",
            bootstrapPassword: randomToken(bytes: generatedPasswordBytes),
            tenantUsername: tenantAccountName,
            tenantUID: tenantAccountUID
        )
    }

    /// Lowercase base32-ish token drawn from the system CSPRNG.
    ///
    /// The alphabet is deliberately narrow: the bootstrap value becomes a macOS
    /// short username, which must satisfy `[a-z0-9_-]`.
    private static func randomToken(bytes count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var raw = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &raw)
        precondition(status == errSecSuccess, "system CSPRNG failed")
        return String(raw.map { alphabet[Int($0) % alphabet.count] })
    }
}
