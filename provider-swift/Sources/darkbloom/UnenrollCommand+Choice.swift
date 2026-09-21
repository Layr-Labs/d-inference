import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

enum UnenrollmentMode: Equatable {
    case fullExit
    case appAttest
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
            throw ValidationError("--force cannot be combined with --keep-serving; migration retains all local data.")
        }
        if keepServing {
            try Self.requireAppAttestOS(osMajor)
            return .appAttest
        }
        if force { return .fullExit }
        guard isInteractive else {
            throw ValidationError("Run darkbloom unenroll in an interactive terminal to choose, or use --keep-serving for App Attest migration. --force fully exits and confirms local-data cleanup.")
        }

        writeLine("Do you want to fully exit Darkbloom or just remove MDM and use App Attest?")
        writeLine("  1. Fully exit Darkbloom — stop providing and offer local-data cleanup.")
        writeLine("  2. Remove only Darkbloom MDM — keep serving with App Attest and retain your data.")
        writeLine("App Attest requires macOS 27 or later and current coordinator approval.")
        if osMajor < 27 {
            writeLine("This Mac runs macOS \(osMajor). Upgrade to macOS 27 or later to use option 2.")
        }
        while true {
            writeLine("Choose 1 or 2, or press Enter to cancel:")
            guard let answer = readInput() else { return .cancel }
            switch answer.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "1": return .fullExit
            case "2":
                try Self.requireAppAttestOS(osMajor)
                return .appAttest
            case "": return .cancel
            default: writeLine("Please enter 1 or 2. No changes have been made.")
            }
        }
    }

    static func requireAppAttestOS(_ majorVersion: Int) throws {
        guard majorVersion >= 27 else {
            throw ValidationError("Removing MDM while keeping this provider online requires macOS 27 or later. Keep the Darkbloom profile installed until you upgrade and the coordinator verifies App Attest.")
        }
    }

    // Keep destructive operations behind the explicit choice. Tests inject
    // handlers so selecting migration/cancel can never touch a real profile,
    // service, configuration directory or keychain.
    static func performUnenrollment(
        mode: UnenrollmentMode,
        stopProvider: () async throws -> Void,
        leave: () throws -> Void,
        migrate: () throws -> Void
    ) async throws {
        switch mode {
        case .cancel: return
        case .appAttest: try migrate()
        case .fullExit:
            try await stopProvider()
            try leave()
        }
    }

    static func stopProviderBeforeUnenrollment() async throws {
        var stop = Stop()
        try await stop.run()
        // `stop` disables launchd/watchdog restarts. A separately foregrounded
        // provider may still be running: never purge identity beneath it, nor
        // signal an arbitrary PID from a local file.
        if let identity = DaemonStateFile.read()?.processIdentity, identity.isCurrent() {
            throw ValidationError("A provider process is still running or shutting down. Stop any foreground darkbloom process, then run unenroll again. Local data has not been removed.")
        }
    }
}
