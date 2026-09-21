/// Enrollment -- App Attest setup on macOS 27+, legacy MDM on older macOS.
///
/// macOS 27+ returns App Attest guidance without network or profile operations.
/// On older macOS:
///
///   1. POST an empty JSON object to `${coordinator}/v1/enroll`.
///   2. Coordinator returns a generic `.mobileconfig` profile.
///   3. Save it to a temp path, `open` it (registers with System Settings),
///      then `open x-apple.systempreferences:com.apple.Profiles-Settings.extension`
///      so the user can click Install.
///
/// The whole flow is idempotent: if `checkMDMEnrollment()` reports this Mac
/// is already enrolled in DARKBLOOM's MDM we short-circuit; enrollment in a
/// foreign MDM is an error (macOS allows one MDM per device). Unenrollment
/// cannot be done programmatically (Apple requires the user to remove the
/// profile via System Settings), so unenroll just opens the profiles pane
/// and optionally cleans up local state.

import Foundation

// MARK: - Errors

public enum EnrollmentError: Error, CustomStringConvertible, Sendable {
    case coordinatorRequestFailed(String)
    case coordinatorReturnedHTTP(Int, body: String)
    case profileWriteFailed(String)
    case managedByOtherMDM(serverURL: String)

    public var description: String {
        switch self {
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

    public init() {}

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
        switch checkMDMEnrollment(coordinatorURL: coordinatorURL) {
        case .enrolledDarkbloom:
            return .mdm(
                profilePath: URL(fileURLWithPath: "/dev/null"),
                alreadyEnrolled: true
            )
        case .enrolledOtherMDM(let serverURL):
            throw EnrollmentError.managedByOtherMDM(serverURL: serverURL)
        case .notEnrolled, .checkFailed:
            // checkFailed proceeds too: a redundant profile download is
            // idempotent/harmless, while refusing here would block enrollment
            // on machines where the profiles tool is transiently unavailable.
            break
        }

        let baseURL = coordinatorHTTPBase(coordinatorURL)
        guard let endpoint = URL(string: "\(baseURL)/v1/enroll") else {
            throw EnrollmentError.coordinatorRequestFailed("invalid URL: \(baseURL)/v1/enroll")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EnrollmentError.coordinatorRequestFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EnrollmentError.coordinatorReturnedHTTP(http.statusCode, body: body)
        }

        let profilePath = URL(fileURLWithPath: NSTemporaryDirectory())
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

// MARK: - Local cleanup helpers (used by unenroll)

public enum LocalDataCleanup: Sendable {
    /// Delete optional pieces of local Darkbloom state. Caller should ask for
    /// confirmation before invoking. Each removal is best-effort -- missing
    /// files are not an error.
    ///
    /// `secureEnclaveKey` (default true) also removes the persistent Secure
    /// Enclave attestation signing key. This is what makes un-enroll /
    /// re-enroll actually fix a bad or derouted key: without it, the same
    /// keychain-backed key survives and the provider keeps failing challenges.
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
            // bad/derouted key is regenerated on the next enroll. Best-effort:
            // missing entitlements or an absent key are not errors. Clear both
            // the current (v2 = defaultLabel) and the legacy (v1) labels.
            try? PersistentEnclaveKey.delete()
            try? PersistentEnclaveKey.delete(label: PersistentEnclaveKey.legacyLabelV1)
        }
    }
}
