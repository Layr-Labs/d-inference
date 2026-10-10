import Foundation
import DarkbloomClusterProtocol

/// Assembles one snapshot from observations already made, and words the
/// results of the operations the console runs. It reads the saved setup
/// itself; the link report and the doctor's report are handed in by whoever
/// ran them.
enum ClusterConsoleObserver {
    /// Longest the installed-file checks of one refresh may take, as `cluster doctor` allows.
    static let installedCheckNanoseconds: UInt64 = 15_000_000_000

    /// `reference` is the saved cluster reference, or the error reading it
    /// gave. `temporary` and `dryRun` are what a fix from this screen would be.
    static func snapshot(link: ClusterLinkReadinessReport, diagnostics: ClusterDiagnosticsReport,
                         reference: Result<ClusterConfigurationReference?, Error>, paths: ClusterUserPaths,
                         candidate: ClusterConsoleCandidate?, temporary: Bool = false, dryRun: Bool = false,
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
        let narration = ClusterConsoleLinkSetup.make(report: link, mayPrompt: false, temporary: temporary, dryRun: dryRun)
        let attended = ClusterConsoleLinkSetup.make(report: link, mayPrompt: true, temporary: temporary, dryRun: dryRun)
        // Errors are shown as the operation worded them, less anything in
        // them that names this Mac or its user.
        let clean = ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path)
        return ClusterConsoleSnapshot(observedAt: ClusterConsoleText.timestamp(now), link: link,
            setup: .init(lines: narration.lines, next: attended.next, fixDevice: attended.fixDevice),
            diagnostics: diagnostics.cleaned(clean), saved: saved.cleaned(clean),
            candidate: candidate.map { ClusterConsoleCandidateSetup.read($0, savedSHA256: saved.configurationSHA256).cleaned(clean) },
            admittedModels: ClusterRuntimeAdapter.admittedModels.map {
                .init(adapterID: $0.adapterID, adapterVersion: $0.adapterVersion, runtimeModelID: $0.runtimeModelID)
            })
    }

    // MARK: - Results

    /// The lines `darkbloom cluster link --fix` prints: the outcome, its
    /// sentence, and for a dry run the commands an approval would run.
    static func result(_ repair: ClusterLinkRepairResult) -> ClusterConsoleActionResult {
        var lines = repair.summaryLines
        // The link command prints an administrator's commands on standard
        // error, which a screen does not have; they are pointed to, not shown.
        if !repair.manualCommands.isEmpty {
            lines.append("This screen has no standard error to print them on: `darkbloom cluster link --fix --dry-run` lists the same commands.")
        }
        return .init(succeeded: repair.outcome.exitCode == 0, lines: lines)
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

    /// What an approval saved. `expectedSHA256` is the digest that was on
    /// screen; the two are the same setup or the approval is reported as failed.
    static func result(_ saved: ClusterConfigurationSaveResult, expectedSHA256: String) -> ClusterConsoleActionResult {
        guard saved.configurationSHA256 == expectedSHA256 else {
            return .init(succeeded: false, lines: [
                "A setup was saved, but not the one that was shown: \(ClusterConsoleText.short(saved.configurationSHA256)) instead of \(ClusterConsoleText.short(expectedSHA256)). Run `darkbloom cluster status` and review it."])
        }
        return .init(succeeded: true, lines: [
            "Saved cluster setup \(ClusterConsoleText.short(saved.configurationSHA256)) with capability \(ClusterConsoleText.short(saved.capabilitySHA256)).",
            "Nothing was started or enabled by saving it; installation, the peer and the model files are checked when a session starts."])
    }

    /// Runs the store's save on a held copy of the reviewed inputs. `save`
    /// is `ClusterConfigurationStore.configure` in the installed command.
    static func approve(_ candidate: ClusterConsoleCandidate, expectedSHA256: String, holdingIn directory: URL,
                        save: (ClusterConsoleReviewedSetup) throws -> ClusterConfigurationSaveResult) -> ClusterConsoleActionResult {
        do {
            let reviewed = try ClusterConsoleReviewedSetup.hold(candidate, expectedSHA256: expectedSHA256, in: directory)
            defer { reviewed.release() }
            return result(try save(reviewed), expectedSHA256: expectedSHA256)
        } catch {
            return .failure(error)
        }
    }
}
