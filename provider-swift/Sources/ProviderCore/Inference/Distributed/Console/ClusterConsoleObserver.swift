import Foundation
import DarkbloomClusterProtocol

/// Assembles one snapshot from observations already made, and words the
/// results of the operations the console runs. It reads the saved setup and
/// the alias record itself; the link report and the doctor's report are handed
/// in by whoever ran them.
enum ClusterConsoleObserver {
    /// Longest the installed-file checks of one refresh may take, as `cluster doctor` allows.
    static let installedCheckNanoseconds: UInt64 = 15_000_000_000

    /// `reference` is the saved cluster reference, or the error reading it gave.
    static func snapshot(link: ClusterLinkReadinessReport, diagnostics: ClusterDiagnosticsReport,
                         reference: Result<ClusterConfigurationReference?, Error>, paths: ClusterUserPaths,
                         candidate: ClusterConsoleCandidate?, run: ClusterLinkToolRunner,
                         now: Date = Date()) -> ClusterConsoleSnapshot {
        let saved: ClusterConsoleSavedSetup
        switch reference {
        case .success(let value):
            saved = .read(reference: value, paths: paths,
                deadline: DispatchTime.now().uptimeNanoseconds + installedCheckNanoseconds)
        case .failure(let error):
            saved = .init(state: .unreadable, error: ClusterConsoleText.bounded(error), configurationSHA256: nil,
                pairing: nil, model: nil, installed: nil)
        }
        // The sentences are the unattended flow's, which never assumes a
        // prompt is open; the decision is the attended flow's.
        let narration = ClusterConsoleLinkSetup.make(report: link, mayPrompt: false)
        let attended = ClusterConsoleLinkSetup.make(report: link, mayPrompt: true)
        return ClusterConsoleSnapshot(observedAt: ClusterConsoleText.timestamp(now), link: link,
            setup: .init(lines: narration.lines, next: attended.next, fixDevice: attended.fixDevice),
            aliases: (try? ClusterConsoleLinkAlias.observe(paths: paths, run: run)) ?? [],
            diagnostics: diagnostics, saved: saved,
            candidate: candidate.map { .read($0, savedSHA256: saved.configurationSHA256) },
            admittedModels: ClusterRuntimeAdapter.admittedModels.map {
                .init(adapterID: $0.adapterID, adapterVersion: $0.adapterVersion, runtimeModelID: $0.runtimeModelID)
            })
    }

    // MARK: - Results

    static func result(_ repair: ClusterLinkRepairResult) -> ClusterConsoleActionResult {
        var lines = repair.summaryLines
        // The command an administrator can run instead names the address, so
        // it is shown only where the link command prints it: on standard error.
        if repair.manualCommand != nil {
            lines.append("Run `darkbloom cluster link --fix` in a terminal to see the command an administrator can run instead.")
        }
        return .init(succeeded: repair.outcome.exitCode == 0, lines: lines)
    }

    static func result(_ preview: ClusterLinkFixPreview) -> ClusterConsoleActionResult {
        .init(succeeded: true, lines: preview.summaryLines)
    }

    /// The lines `darkbloom cluster recover` prints.
    static func result(_ report: ClusterDeviceRecovery.Report) -> ClusterConsoleActionResult {
        var lines = ["Device journal: \(report.outcome.rawValue)"]
        if let record = report.record {
            lines.append("Recorded session: cluster \(record.clusterID), member \(record.peerID) rank \(record.rank), epoch \(record.membershipEpoch)")
        }
        lines.append(report.detail)
        return .init(succeeded: report.journalEmpty, lines: lines)
    }

    static func result(_ saved: ClusterConfigurationSaveResult) -> ClusterConsoleActionResult {
        .init(succeeded: true, lines: [
            "Saved cluster setup \(ClusterConsoleText.short(saved.configurationSHA256)) with capability \(ClusterConsoleText.short(saved.capabilitySHA256)).",
            "Distributed startup remains disabled. Installation, remote trust, model files and readiness still require checks."])
    }
}
