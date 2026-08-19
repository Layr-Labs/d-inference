/// Enrollment -- MDM device-attestation flow.
///
/// Flow:
///
///   1. Read the hardware serial number via `ioreg`.
///   2. POST `{"serial_number": ...}` to `${coordinator}/v1/enroll`.
///   3. Coordinator returns a per-device `.mobileconfig` profile.
///   4. Save it to a temp path, `open` it (registers with System Settings),
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

// MARK: - Hardware serial

/// Read the Mac's hardware serial number via `ioreg`. Returns nil if it
/// can't be parsed (unlikely on real hardware; hits in test envs).
public func macHardwareSerialNumber() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-c", "IOPlatformExpertDevice", "-d", "2"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    for line in text.split(separator: "\n") {
        guard line.contains("IOPlatformSerialNumber") else { continue }
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        // ioreg format:  "IOPlatformSerialNumber" = "C02XXXXX..."
        // Splitting on " yields:  [..., "IOPlatformSerialNumber", " = ", "C02..."]
        if parts.count >= 4 {
            let candidate = String(parts[3])
            if !candidate.isEmpty {
                return candidate
            }
        }
    }
    return nil
}

// MARK: - Errors

public enum EnrollmentError: Error, CustomStringConvertible, Sendable {
    case serialNumberUnavailable
    case coordinatorRequestFailed(String)
    case coordinatorReturnedHTTP(Int, body: String)
    case profileWriteFailed(String)
    case profileOpenFailed(String)
    case systemSettingsOpenFailed(String)
    case managedByOtherMDM(serverURL: String)

    public var description: String {
        switch self {
        case .serialNumberUnavailable:
            return "Could not read hardware serial number from ioreg."
        case .coordinatorRequestFailed(let detail):
            return "Failed to reach coordinator: \(detail)"
        case .coordinatorReturnedHTTP(let status, let body):
            return "Coordinator returned HTTP \(status): \(body)"
        case .profileWriteFailed(let detail):
            return "Failed to write enrollment profile: \(detail)"
        case .profileOpenFailed(let detail):
            return "The enrollment profile was downloaded, but macOS could not open it: \(detail). Open the profile manually, then install it in System Settings → General → Device Management."
        case .systemSettingsOpenFailed(let detail):
            return "The enrollment profile opened, but System Settings could not be opened automatically: \(detail). Open System Settings → General → Device Management to finish installation."
        case .managedByOtherMDM(let serverURL):
            return "This Mac is already managed by another MDM (server: \(serverURL)). "
                + "macOS allows only one MDM enrollment per device, so Darkbloom "
                + "enrollment is unavailable here. If that profile is yours to "
                + "remove: System Settings → General → Device Management, then "
                + "re-run `darkbloom enroll`."
        }
    }
}

// MARK: - Enrollment service

public struct EnrollmentResult: Sendable {
    public let serialNumber: String
    public let profilePath: URL
    public let alreadyEnrolled: Bool
    public let profileOpened: Bool
    public let openWarning: String?

    public init(
        serialNumber: String,
        profilePath: URL,
        alreadyEnrolled: Bool,
        profileOpened: Bool = false,
        openWarning: String? = nil
    ) {
        self.serialNumber = serialNumber
        self.profilePath = profilePath
        self.alreadyEnrolled = alreadyEnrolled
        self.profileOpened = profileOpened
        self.openWarning = openWarning
    }
}

/// Drives the MDM enrollment flow against a coordinator.
///
/// Stateless: callers pass the coordinator HTTP base URL. The service
/// downloads the profile, saves it to a temp path, and (on macOS) opens
/// System Settings.
public struct EnrollmentService: Sendable {
    typealias OpenCommand = @Sendable ([String]) throws -> Void
    typealias Pause = @Sendable () async throws -> Void

    private let openCommand: OpenCommand
    private let pauseBeforeOpeningSettings: Pause

    public init() {
        openCommand = Self.runOpen
        pauseBeforeOpeningSettings = {
            try await Task.sleep(for: .seconds(1))
        }
    }

    init(
        openCommand: @escaping OpenCommand,
        pauseBeforeOpeningSettings: @escaping Pause = {}
    ) {
        self.openCommand = openCommand
        self.pauseBeforeOpeningSettings = pauseBeforeOpeningSettings
    }

    /// Request a per-device enrollment profile and (on macOS) open the
    /// System Settings pane so the user can install it.
    ///
    /// - Parameters:
    ///   - coordinatorURL: HTTPS coordinator base URL (not the WebSocket URL).
    ///     The function will normalize a `wss://...` value via `coordinatorHTTPBase`.
    ///   - openSystemSettings: When true, opens the .mobileconfig and the
    ///     Profiles pane. Set to false in tests / non-interactive runs.
    /// - Returns: Where the profile was written and whether enrollment was
    ///   skipped because the device already had a profile.
    public func enroll(
        coordinatorURL: String,
        openSystemSettings: Bool = true
    ) async throws -> EnrollmentResult {
        switch checkMDMEnrollment(coordinatorURL: coordinatorURL) {
        case .enrolledDarkbloom:
            return EnrollmentResult(
                serialNumber: macHardwareSerialNumber() ?? "<unknown>",
                profilePath: URL(fileURLWithPath: "/dev/null"),
                alreadyEnrolled: true,
                profileOpened: false
            )
        case .enrolledOtherMDM(let serverURL):
            throw EnrollmentError.managedByOtherMDM(serverURL: serverURL)
        case .notEnrolled, .checkFailed:
            // checkFailed proceeds too: a redundant profile download is
            // idempotent/harmless, while refusing here would block enrollment
            // on machines where the profiles tool is transiently unavailable.
            break
        }

        guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
            throw EnrollmentError.serialNumberUnavailable
        }

        let baseURL = coordinatorHTTPBase(coordinatorURL)
        guard let endpoint = URL(string: "\(baseURL)/v1/enroll") else {
            throw EnrollmentError.coordinatorRequestFailed("invalid URL: \(baseURL)/v1/enroll")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["serial_number": serial]
        )

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
            .appendingPathComponent("Darkbloom-Enroll-\(serial).mobileconfig")
        do {
            try data.write(to: profilePath, options: .atomic)
        } catch {
            throw EnrollmentError.profileWriteFailed(error.localizedDescription)
        }

        let profileOpened: Bool
        let openWarning: String?
        if openSystemSettings {
            openWarning = try await openDownloadedProfile(at: profilePath)
            profileOpened = true
        } else {
            openWarning = nil
            profileOpened = false
        }

        return EnrollmentResult(
            serialNumber: serial,
            profilePath: profilePath,
            alreadyEnrolled: false,
            profileOpened: profileOpened,
            openWarning: openWarning
        )
    }

    /// Opening the profile is the success boundary for `profile_opened`.
    /// Opening the pane is a convenience; its failure is returned as an
    /// actionable warning because the downloaded profile has already opened.
    func openDownloadedProfile(at profilePath: URL) async throws -> String? {
        do {
            try openCommand([profilePath.path])
        } catch {
            throw EnrollmentError.profileOpenFailed(Self.errorDetail(error))
        }

        try await pauseBeforeOpeningSettings()
        do {
            try openCommand([
                "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
            ])
            return nil
        } catch {
            return EnrollmentError.systemSettingsOpenFailed(
                Self.errorDetail(error)
            ).description
        }
    }

    /// Open the System Settings → Device Management pane so the user can
    /// remove the profile. Apple requires user interaction; we cannot remove
    /// it programmatically.
    public func openProfilesPaneForRemoval() {
        try? openCommand([
            "x-apple.systempreferences:com.apple.preferences.configurationprofiles"
        ])
    }

    private static func runOpen(arguments: [String]) throws {
        try BoundedProcess.run(
            URL(fileURLWithPath: "/usr/bin/open"),
            arguments: arguments,
            timeout: 15,
            captureStderrTail: 4_096
        )
    }

    private static func errorDetail(_ error: Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
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
