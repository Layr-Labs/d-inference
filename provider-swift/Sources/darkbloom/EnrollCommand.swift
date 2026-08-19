import ArgumentParser
import Foundation
import ProviderCore

struct Enroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enroll this Mac in Darkbloom MDM (device-attestation profile).",
        discussion: """
        Requests a per-device .mobileconfig profile from the coordinator,
        opens it (registering with System Settings), then opens the
        Profiles pane so you can click Install. The profile lets the
        coordinator verify that SIP/Secure Boot are on and that the
        Secure Enclave is genuine Apple hardware.

        Darkbloom CANNOT erase, lock, or remotely control your Mac.
        Remove anytime in System Settings → Device Management.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator URL (HTTPS).")
    var coordinator: String?

    @Flag(help: "Don't open System Settings; just download the profile.")
    var noOpen = false

    @Flag(help: "Emit one machine-readable JSON result (schema 1) as the only stdout output.")
    var json = false

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let coordinatorURL = coordinator
            ?? snapshot.config.coordinator.url
        try await execute(
            coordinatorURL: coordinatorURL,
            enroll: { coordinatorURL, openSystemSettings in
                try await EnrollmentService().enroll(
                    coordinatorURL: coordinatorURL,
                    openSystemSettings: openSystemSettings
                )
            },
            output: { print($0) },
            errorOutput: { printError($0) }
        )
    }

    /// Runs one enrollment attempt through an injectable service boundary.
    /// Production passes `EnrollmentService`; tests pass a non-mutating stub.
    func execute(
        coordinatorURL: String,
        enroll: EnrollmentOperation,
        output: (String) -> Void,
        errorOutput: (String) -> Void
    ) async throws {
        if !json {
            output(EnrollmentHumanRenderer.preamble(
                coordinator: coordinatorHTTPBase(coordinatorURL)
            ))
        }

        let serviceResult: EnrollmentResult
        do {
            serviceResult = try await enroll(coordinatorURL, !noOpen)
        } catch let error as EnrollmentError {
            // The schema has only successful terminal states. Operational
            // failures therefore stay on stderr and leave JSON stdout empty.
            errorOutput(error.description)
            throw ExitCode.failure
        }

        let result = EnrollmentCommandResult(
            serviceResult: serviceResult
        )
        if json {
            output(try EnrollmentJSONRenderer.render(result))
        } else {
            output(EnrollmentHumanRenderer.completion(result))
        }
    }
}

typealias EnrollmentOperation = @Sendable (
    _ coordinatorURL: String,
    _ openSystemSettings: Bool
) async throws -> EnrollmentResult

/// The one normalized enrollment outcome rendered by both CLI output modes.
struct EnrollmentCommandResult: Encodable, Equatable, Sendable {
    enum Status: String, Encodable, Sendable {
        case alreadyEnrolled = "already_enrolled"
        case profileOpened = "profile_opened"
        case profileDownloaded = "profile_downloaded"
    }

    let schema = 1
    let status: Status
    let serialNumber: String
    let profilePath: String?
    let warning: String?

    init(serviceResult: EnrollmentResult) {
        serialNumber = serviceResult.serialNumber
        warning = serviceResult.openWarning
        if serviceResult.alreadyEnrolled {
            status = .alreadyEnrolled
            profilePath = nil
        } else {
            status = serviceResult.profileOpened ? .profileOpened : .profileDownloaded
            profilePath = serviceResult.profilePath.path
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case status
        case serialNumber = "serial_number"
        case profilePath = "profile_path"
        case warning
    }
}

enum EnrollmentJSONRenderer {
    static func render(_ result: EnrollmentCommandResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        return String(decoding: data, as: UTF8.self)
    }
}

enum EnrollmentHumanRenderer {
    static func preamble(coordinator: String) -> String {
        """
        Darkbloom Device Attestation Enrollment
        Coordinator: \(coordinator)

        """
    }

    static func completion(_ result: EnrollmentCommandResult) -> String {
        switch result.status {
        case .alreadyEnrolled:
            return """
              ✓ Already enrolled — no action needed.
              Verify with: darkbloom doctor
            """
        case .profileDownloaded:
            return """
              → Device serial:  \(result.serialNumber)
              → Profile saved:  \(result.profilePath ?? "")

              Install the profile manually:
                open \(result.profilePath ?? "")

            After installing, verify with: darkbloom doctor
            """
        case .profileOpened:
            if let warning = result.warning {
                return """
                  → Device serial:  \(result.serialNumber)
                  → Profile saved:  \(result.profilePath ?? "")

                  Warning: \(warning)

                  The enrollment profile opened. Finish installation in System Settings → General → Device Management.
                After installing, verify with: darkbloom doctor
                """
            }
            return """
              → Device serial:  \(result.serialNumber)
              → Profile saved:  \(result.profilePath ?? "")

              System Settings → Device Management is now open.
              Click Install on the Darkbloom profile and enter your password.

              This verifies:
                • SIP, Secure Boot, and system integrity
                • Your Secure Enclave is genuine Apple hardware
                • Device identity signed by Apple's Root CA

              Darkbloom CANNOT erase, lock, or control your Mac.
            After installing, verify with: darkbloom doctor
            """
        }
    }
}
