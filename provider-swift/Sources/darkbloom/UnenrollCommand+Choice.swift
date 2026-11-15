import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

enum UnenrollmentMode: Equatable {
    case fullExit
    case removeRetiredProfile
    case cancel
}

extension Unenroll {
    func chooseUnenrollmentMode(
        isInteractive: Bool = isatty(STDIN_FILENO) != 0,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        readInput: () -> String? = { readLine() },
        writeLine: (String) -> Void = { print($0) }
    ) throws -> UnenrollmentMode {
        guard !(keepServing && force) else {
            throw ValidationError("--force cannot be combined with --keep-serving; removing the profile retains all local data.")
        }
        if keepServing { return .removeRetiredProfile }
        if force { return .fullExit }
        guard isInteractive else {
            throw ValidationError("Run \(BuildEnvironment.current.cliName) unenroll in an interactive terminal to choose, or use --keep-serving to remove only the retired Darkbloom MDM profile. --force fully exits and confirms local-data cleanup.")
        }

        writeLine("Do you want to fully exit Darkbloom, or only remove the old Darkbloom MDM profile?")
        writeLine("  1. Fully exit Darkbloom — stop providing and offer local-data cleanup.")
        writeLine("  2. Remove only the Darkbloom MDM profile — keep the provider, your account and your data.")
        writeLine("Darkbloom no longer uses its MDM profile: Macs are verified with App Attest (macOS 27 or later).")
        if !ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: osMajor) {
            writeLine("This Mac runs macOS \(osMajor) and cannot serve until it is updated to macOS 27 or later; removing the profile does not change that.")
        }
        while true {
            writeLine("Choose 1 or 2, or press Enter to cancel:")
            guard let answer = readInput() else { return .cancel }
            switch answer.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "1": return .fullExit
            case "2": return .removeRetiredProfile
            case "": return .cancel
            default: writeLine("Please enter 1 or 2. No changes have been made.")
            }
        }
    }

    // Keep destructive operations behind the explicit choice. Tests inject
    // handlers so selecting profile removal/cancel can never touch a real
    // profile, service, configuration directory or keychain.
    static func performUnenrollment(
        mode: UnenrollmentMode,
        stopProvider: () async throws -> Void,
        leave: () throws -> Void,
        removeProfile: () throws -> Void
    ) async throws {
        switch mode {
        case .cancel: return
        case .removeRetiredProfile: try removeProfile()
        case .fullExit:
            try await stopProvider()
            try leave()
        }
    }

    /// The stop unenrollment runs first: single-Mac serving, as `darkbloom stop --solo` (it never stops a pair).
    static func stopCommand() throws -> Stop { try Stop.parse(["--solo"]) }

    static func stopProviderBeforeUnenrollment() async throws {
        var stop = try stopCommand()
        try await DarkbloomCommandLook.runNested { try await stop.run() }
        // `stop` disables launchd/watchdog restarts. A separately foregrounded
        // provider may still be running: never purge identity beneath it, nor
        // signal an arbitrary PID from a local file.
        if let identity = DaemonStateFile.read()?.processIdentity, identity.isCurrent() {
            throw ValidationError("A provider process is still running or shutting down. Stop any foreground \(BuildEnvironment.current.cliName) process, then run unenroll again. Local data has not been removed.")
        }
    }
}
