/// Enrollment -- App Attest setup on macOS 27+, legacy MDM on older macOS.
///
/// macOS 27+ returns App Attest guidance without network or profile operations.
/// On older macOS:
///
///   1. POST an authenticated proof from the existing linked account and
///      persistent Secure Enclave key to `${coordinator}/v1/enroll`.
///   2. Coordinator returns a generic `.mobileconfig` profile.
///   3. Save it to a temp path, `open` it (registers with System Settings),
///      then `open x-apple.systempreferences:com.apple.Profiles-Settings.extension`
///      so the user can click Install.
///
/// The whole flow is idempotent: if `checkMDMEnrollment()` reports this Mac
/// is already enrolled in DARKBLOOM's MDM we validate eligibility but skip
/// installation; enrollment in a foreign MDM is an error (macOS allows one
/// MDM per device). Unenrollment
/// cannot be done programmatically (Apple requires the user to remove the
/// profile via System Settings), so unenroll just opens the profiles pane
/// and optionally cleans up local state.

import CryptoKit
import Foundation
import Security

// MARK: - Errors

public enum EnrollmentError: Error, CustomStringConvertible, Sendable {
    case linkedCredentialsRequired
    case existingIdentityRequired(String)
    case coordinatorRequestFailed(String)
    case coordinatorReturnedHTTP(Int, body: String)
    case profileWriteFailed(String)
    case managedByOtherMDM(serverURL: String)

    public var description: String {
        switch self {
        case .linkedCredentialsRequired:
            return "New providers require macOS 27 or later and coordinator-qualified App Attest. "
                + "Legacy MDM is only for grandfathered account/key pairs. "
                + "Run 'darkbloom login' with the existing linked account to check eligibility."
        case .existingIdentityRequired(let detail):
            return "New providers require macOS 27 or later and coordinator-qualified App Attest. "
                + "Legacy MDM requires the grandfathered account's original Secure Enclave key; "
                + "no replacement key was created. Existing identity unavailable: \(detail)"
        case .coordinatorRequestFailed(let detail):
            return "Failed to reach coordinator: \(detail)"
        case .coordinatorReturnedHTTP(let status, let body):
            return "Coordinator returned HTTP \(status): \(body)"
        case .profileWriteFailed(let detail):
            return "Failed to write enrollment profile: \(detail)"
        case .managedByOtherMDM(let serverURL):
            return "This Mac is already managed by another MDM (server: \(serverURL)). "
                + "macOS allows only one MDM enrollment per device, so Darkbloom "
                + "enrollment is unavailable here. Keep your organization's profile installed. "
                + "Upgrade to macOS 27 or later, start the current provider and check `darkbloom status` for "
                + "coordinator-qualified App Attest serving."
        }
    }
}

// MARK: - Enrollment service

public enum EnrollmentResult: Sendable {
    case appAttest
    case mdm(profilePath: URL, alreadyEnrolled: Bool)
}

/// Chooses App Attest setup or drives legacy MDM enrollment.
///
/// Stateless: callers pass the coordinator HTTP base URL. The service
/// downloads a profile and opens System Settings only on older macOS.
public struct EnrollmentService: Sendable {
    private let checkEnrollment: @Sendable (String) -> MDMEnrollmentState
    private let loadToken: @Sendable () -> String?
    private let loadSigner: @Sendable () throws -> any AttestationSigner
    private let profileDirectory: URL

    public init() {
        self.init(checkEnrollment: { checkMDMEnrollment(coordinatorURL: $0) })
    }

    init(
        checkEnrollment: @escaping @Sendable (String) -> MDMEnrollmentState,
        loadToken: @escaping @Sendable () -> String? = { AuthTokenStore.load() },
        loadSigner: @escaping @Sendable () throws -> any AttestationSigner = { try EnrollmentPersistentSigner() },
        profileDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.checkEnrollment = checkEnrollment
        self.loadToken = loadToken
        self.loadSigner = loadSigner
        self.profileDirectory = profileDirectory
    }

    /// Request a per-device enrollment profile and (on macOS) open the
    /// System Settings pane so the user can install it.
    ///
    /// - Parameters:
    ///   - coordinatorURL: HTTPS coordinator base URL (not the WebSocket URL).
    ///     The function will normalize a `wss://...` value via `coordinatorHTTPBase`.
    ///   - openSystemSettings: When true, opens the .mobileconfig and the
    ///     Profiles pane. Set to false in tests / non-interactive runs.
    ///   - macOSMajorVersion: Local OS major version; injectable for setup tests.
    /// - Returns: App Attest guidance without downloading/opening a profile on
    ///   macOS 27+, or the legacy profile and existing-enrollment state.
    public func enroll(
        coordinatorURL: String,
        openSystemSettings: Bool = true,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) async throws -> EnrollmentResult {
        // OS version chooses onboarding, never trust. Unsupported/unqualified
        // App Attest stays pending at the coordinator, without an MDM fallback.
        if ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) {
            return .appAttest
        }
        let alreadyEnrolled: Bool
        switch checkEnrollment(coordinatorURL) {
        case .enrolledDarkbloom:
            alreadyEnrolled = true
        case .enrolledOtherMDM(let serverURL):
            throw EnrollmentError.managedByOtherMDM(serverURL: serverURL)
        case .notEnrolled, .checkFailed:
            // checkFailed proceeds too: a redundant profile download is
            // idempotent/harmless, while refusing here would block enrollment
            // on machines where the profiles tool is transiently unavailable.
            alreadyEnrolled = false
        }

        let baseURL = coordinatorHTTPBase(coordinatorURL)
        guard let endpoint = URL(string: "\(baseURL)/v1/enroll") else {
            throw EnrollmentError.coordinatorRequestFailed("invalid URL: \(baseURL)/v1/enroll")
        }

        let request = try Self.profileRequest(
            endpoint: endpoint, loadToken: loadToken, loadSigner: loadSigner)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EnrollmentError.coordinatorRequestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EnrollmentError.coordinatorRequestFailed("expected an HTTP eligibility response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EnrollmentError.coordinatorReturnedHTTP(http.statusCode, body: body)
        }

        // A local profile can be copied or linked to a different account. Only
        // the authenticated coordinator response proves legacy eligibility.
        if alreadyEnrolled {
            return .mdm(profilePath: URL(fileURLWithPath: "/dev/null"), alreadyEnrolled: true)
        }

        let profilePath = profileDirectory
            .appendingPathComponent("Darkbloom-Enroll-\(UUID().uuidString).mobileconfig")
        do {
            try data.write(to: profilePath, options: .atomic)
        } catch {
            throw EnrollmentError.profileWriteFailed(error.localizedDescription)
        }

        if openSystemSettings {
            // Step 1: register with System Settings by opening the .mobileconfig.
            _ = try? runOpen(arguments: [profilePath.path])
            // Tiny pause so the profile registers before we open the pane.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // Step 2: open System Settings → Profiles directly.
            _ = try? runOpen(arguments: [
                "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
            ])
        }

        return .mdm(
            profilePath: profilePath,
            alreadyEnrolled: false
        )
    }

    /// Builds the proof before any network or profile operations. The server
    /// decides whether this account/key pair is in its frozen legacy cohort.
    static func profileRequest(
        endpoint: URL,
        loadToken: () -> String? = { AuthTokenStore.load() },
        loadSigner: () throws -> any AttestationSigner = { try EnrollmentPersistentSigner() },
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws -> URLRequest {
        guard let token = loadToken(), !token.isEmpty else {
            throw EnrollmentError.linkedCredentialsRequired
        }
        let signer: any AttestationSigner
        do {
            signer = try loadSigner()
        } catch {
            throw EnrollmentError.existingIdentityRequired(String(describing: error))
        }
        let publicKey = signer.publicKeyBase64
        let tokenHash = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let message = Data("darkbloom-mdm-enroll-v1\n\(tokenHash)\n\(publicKey)\n\(timestamp)".utf8)
        let signature = try signer.sign(message)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(ProfileProof(
            se_public_key: publicKey, timestamp: timestamp,
            signature: signature.base64EncodedString()))
        return request
    }

    private struct ProfileProof: Encodable {
        let se_public_key: String
        let timestamp: Int64
        let signature: String
    }

    /// Open the System Settings → Device Management pane so the user can
    /// remove the profile. Apple requires user interaction; we cannot remove
    /// it programmatically.
    public func openProfilesPaneForRemoval() {
        _ = try? runOpen(arguments: [
            "x-apple.systempreferences:com.apple.preferences.configurationprofiles"
        ])
    }

    private func runOpen(arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Lookup-only access to the attestation identity: loadOrCreate and its repair
/// path must not mint a replacement key that cannot be grandfathered.
private struct EnrollmentPersistentSigner: AttestationSigner, @unchecked Sendable {
    let privateKey: SecKey
    let publicKeyBase64: String

    init() throws {
        let override = ProcessInfo.processInfo.environment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"]
        let group = override.flatMap { $0.isEmpty ? nil : $0 } ?? PersistentEnclaveKey.defaultAccessGroup
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: PersistentEnclaveKey.defaultLabel,
            kSecAttrAccessGroup as String: group,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            throw PersistentEnclaveKeyError.missingEntitlement
        }
        guard status == errSecSuccess, let result else {
            throw PersistentEnclaveKeyError.keyLookupFailed(status: status)
        }
        privateKey = result as! SecKey
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw PersistentEnclaveKeyError.publicKeyExtractionFailed
        }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let detail = error?.takeRetainedValue() as Error? as NSError?
            throw PersistentEnclaveKeyError.publicKeySerializationFailed(
                status: OSStatus(detail?.code ?? Int(errSecInternalError)))
        }
        guard raw.count == 65, raw[0] == 0x04 else {
            throw PersistentEnclaveKeyError.publicKeyExtractionFailed
        }
        publicKeyBase64 = Data(raw.dropFirst()).base64EncodedString()
    }

    func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error
        ) as Data? else {
            let detail = error?.takeRetainedValue() as Error? as NSError?
            throw PersistentEnclaveKeyError.signingFailed(
                status: OSStatus(detail?.code ?? Int(errSecInternalError)),
                message: detail?.localizedDescription ?? "unknown error")
        }
        return signature
    }
}

// MARK: - Local cleanup helpers (used by unenroll)

public enum LocalDataCleanup: Sendable {
    /// Delete optional pieces of local Darkbloom state. Caller should ask for
    /// confirmation before invoking. Each removal is best-effort -- missing
    /// files are not an error.
    ///
    /// `secureEnclaveKey` (default true) also removes the persistent Secure
    /// Enclave attestation signing key. Provider startup can create a new key,
    /// but that replacement does not inherit legacy MDM enrollment eligibility.
    public static func purge(
        configDirectory: Bool = true,
        legacyKeyFiles: Bool = true,
        authToken: Bool = true,
        secureEnclaveKey: Bool = true
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        if configDirectory {
            for relative in [".config/darkbloom", ".config/eigeninference"] {
                let dir = home.appendingPathComponent(relative)
                try? fm.removeItem(at: dir)
            }
        }
        if legacyKeyFiles {
            let darkbloomDir = home.appendingPathComponent(".darkbloom")
            for name in ["wallet_key", "enclave_key.data", "node_key", "secret_key"] {
                try? fm.removeItem(at: darkbloomDir.appendingPathComponent(name))
            }
        }
        if authToken {
            try? AuthTokenStore.delete()
        }
        if secureEnclaveKey {
            // Remove the persistent Secure Enclave attestation signing key so a
            // bad/derouted key can be regenerated on provider startup. Best-effort:
            // missing entitlements or an absent key are not errors.
            try? PersistentEnclaveKey.delete()
        }
    }
}
