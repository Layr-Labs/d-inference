import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status",
            abstract: "Show saved setup and a fresh local leader observation, without starting inference.")
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print saved configuration and explicitly scoped live evidence as JSON.") var json = false
        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let report = await ClusterDiagnostics.status(providerConfiguration: try diagnosticsPath(configOptions.config))
            try printDiagnostics(report, json: json)
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "doctor",
            abstract: "Check local installed metadata and trust files without inference, SSH probes or recovery.")
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print each check's observed, failed or not-run scope as JSON.") var json = false
        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let report = await ClusterDiagnostics.doctor(providerConfiguration: try diagnosticsPath(configOptions.config))
            try printDiagnostics(report, json: json)
            if report.checks.contains(where: { $0.outcome == .failed }) { throw ExitCode.failure }
        }
    }
}

private func diagnosticsPath(_ input: String?) throws -> URL {
    let path = try input ?? ConfigManager.defaultConfigPath().path
    guard path.hasPrefix("/"), !path.contains("\0") else {
        throw ValidationError("Cluster diagnostics require an absolute provider configuration path.")
    }
    return URL(fileURLWithPath: path)
}

private func printDiagnostics(_ report: ClusterDiagnosticsReport, json: Bool) throws {
    if json { try printJSON(report); return }
    print("Saved setup: \(report.configurationState.rawValue)")
    if let saved = report.saved {
        print("Cluster: \(saved.clusterID) · member \(saved.memberID) (\(saved.role.rawValue))")
        print("Model: \(saved.publicModelID) · selected prefill: \(saved.prefillSchedule.rawValue)")
    }
    if let live = report.live {
        print("Live leader: \(live.ready ? "ready" : "not ready") · admission \(live.admissionAvailable ? "available" : "closed") · \(live.hostPhase)")
        print("Response authentication: \(live.authenticationConfigured ? "configured bearer" : "not configured (--no-auth)")")
        print("Epoch: \(live.session.observedMembershipEpoch ?? "not observed") · MTP off: \(live.session.mtpOffReason)")
        if let state = live.session.admission {
            print("Lifetime remaining: \(state.remainingLifetimeNanoseconds / 1_000_000) ms · admissions: \(state.remainingRequests) · active: \(state.activeRequest)")
        }
        for peer in live.session.members {
            print("  \(peer.peerID) rank \(peer.rank): \(peer.transport.rawValue), ready \(peer.nativeReady), native cleanup \(peer.nativeCleanupObserved), release ACK \(peer.ownerReleaseAcknowledged)")
        }
        if live.quarantined { print("Quarantined: retained ownership is unresolved.") }
    } else { print("Live leader: not observed; saved configuration is not readiness.") }
    print("Device journal: \(report.deviceJournal.rawValue) (no availability or orphan proof)")
    for check in report.checks { print("[\(check.outcome.rawValue)] \(check.name): \(check.detail)") }
}
