import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status",
            abstract: "Say whether the cluster serves now, and if not, why and what to do (--json for scripts).",
            discussion: """
                Prints which Mac leads, the model and how it is split, whether it serves through Darkbloom or \
                locally only, whether it serves now (the reasons `darkbloom cluster` shows) and what to do next. On \
                the Mac that follows, the leading Mac is asked over the cable. Nothing is started or changed.

                Exit status: 0 serving; 3 not serving yet (loading, or a reason); 4 stopped; 5 the other Mac isn't \
                answering; 6 this Mac isn't in a cluster; 7 this Mac's pairing record couldn't be read. --json prints the same as one JSON object with the same exit \
                status. --details prints the saved setup and the leading Mac's session for support, as earlier \
                versions printed by default (with --json, that report).
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print the status as one JSON object (schema 1), with the same exit status.") var json = false
        @Flag(help: "Print the saved setup and the leading Mac's live session for support (the earlier output); with --json, that report.")
        var details = false
        mutating func run() async throws {
            Darkbloom.ensureLogging()
            guard details else {
                let summary = await ClusterPairSummary.live(config: configOptions.config,
                                                            bounded: json ? ClusterPairSummary.sayOnStandardError : ClusterPairCommands.printLine)
                if json { try printJSON(summary.json) } else { for line in summary.clusterStatusLines { print(line) } }
                if summary.exitCode != 0 { throw ExitCode(summary.exitCode) }
                return
            }
            let path = try diagnosticsPath(configOptions.config)
            let report = await ClusterDiagnostics.status(providerConfiguration: path)
            // What each Mac holds is the plan's figure from the model's own files; it is printed
            // with the saved setup, and the JSON report, whose schema is fixed, is left as it is.
            let holdings = json || report.saved == nil ? nil : ClusterDiagnostics.holdings(providerConfiguration: path)
            try printDiagnostics(report, json: json, holdings: holdings?.line)
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "doctor",
            abstract: "Check local installed metadata, trust files and this Mac's RDMA link state without inference, SSH probes or recovery.")
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

private func printDiagnostics(_ report: ClusterDiagnosticsReport, json: Bool, holdings: String? = nil) throws {
    if json { try printJSON(report); return }
    print("Saved setup: \(report.configurationState.rawValue)")
    if let saved = report.saved {
        print("Cluster: \(saved.clusterID) · member \(saved.memberID) (\(saved.role.rawValue))")
        print("Model: \(saved.publicModelID) · selected prefill: \(saved.prefillSchedule.rawValue) · generation mode: \(saved.generationMode.rawValue)")
        for peer in saved.peers {
            print("  \(peer.id) rank \(peer.rank) worker supports: \(peer.supportedGenerationModes.map(\.rawValue).joined(separator: ", "))")
        }
        if let holdings { print(holdings) }
    }
    if let live = report.live {
        print("Live leader: \(live.ready ? "ready" : "not ready") · admission \(live.admissionAvailable ? "available" : "closed") · \(live.hostPhase)")
        print("Response authentication: \(live.authenticationConfigured ? "configured bearer" : "not configured (--no-auth)")")
        print("Epoch: \(live.session.observedMembershipEpoch ?? "not observed") · "
            + (live.session.mtpEnabled ? "MTP: on (decode verifies drafts of the model's own speculative head)" : "MTP off: \(live.session.mtpOffReason)"))
        print("Running generation mode: \(live.session.observedGenerationMode?.rawValue ?? "not observed")")
        if let state = live.session.admission {
            print("Requests served: \(state.requestsServed) · keep-warm exchanges: \(state.keepWarmExchanges) · active: \(state.activeRequest)")
        }
        for peer in live.session.members {
            print("  \(peer.peerID) rank \(peer.rank): \(peer.transport.rawValue), ready \(peer.nativeReady), native cleanup \(peer.nativeCleanupObserved), release ACK \(peer.ownerReleaseAcknowledged)")
        }
        if live.quarantined { print("Quarantined: retained ownership is unresolved.") }
    } else { print("Live leader: not observed; saved configuration is not readiness.") }
    print("Device journal: \(report.deviceJournal.rawValue) (no availability or orphan proof)")
    for line in report.observabilityLines { print(line) }
    for check in report.checks { print("[\(check.outcome.rawValue)] \(check.name): \(check.detail)") }
}
