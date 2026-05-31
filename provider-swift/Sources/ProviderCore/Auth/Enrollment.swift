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
/// The whole flow is idempotent: if `checkMDMEnrolled()` already returns
/// true we short-circuit. Unenrollment cannot be done programmatically
/// (Apple requires the user to remove the profile via System Settings),
/// so unenroll just opens the profiles pane and optionally cleans up local
/// state.

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
        }
    }
}

// MARK: - Enrollment service

public struct EnrollmentResult: Sendable {
    public let serialNumber: String
    public let profilePath: URL
    public let alreadyEnrolled: Bool
}

/// Drives the MDM enrollment flow against a coordinator.
///
/// Stateless: callers pass the coordinator HTTP base URL. The service
/// downloads the profile, saves it to a temp path, and (on macOS) opens
/// System Settings.
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
    /// - Returns: Where the profile was written and whether enrollment was
    ///   skipped because the device already had a profile.
    public func enroll(
        coordinatorURL: String,
        openSystemSettings: Bool = true
    ) async throws -> EnrollmentResult {
        if checkMDMEnrolled() {
            return EnrollmentResult(
                serialNumber: macHardwareSerialNumber() ?? "<unknown>",
                profilePath: URL(fileURLWithPath: "/dev/null"),
                alreadyEnrolled: true
            )
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

        return EnrollmentResult(
            serialNumber: serial,
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
