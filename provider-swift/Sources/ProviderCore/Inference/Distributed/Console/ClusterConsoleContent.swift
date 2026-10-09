import Foundation

/// One line of the screen before it is fitted to a width.
public struct ClusterConsoleLine: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case title, heading, normal, good, warning, bad, dim, prompt }
    public let text: String
    public let style: Style
    /// Leading columns, kept when the line wraps.
    public let indent: Int

    init(_ text: String, _ style: Style = .normal, indent: Int = 2) {
        self.text = text; self.style = style; self.indent = indent
    }

    static func heading(_ text: String) -> ClusterConsoleLine { .init(text, .heading, indent: 0) }
    static let blank = ClusterConsoleLine("", .normal, indent: 0)
}

/// What the screen says, section by section, from the state alone. Every
/// sentence reports an observation, a result, or that something was not
/// observed. The same lines, without the interactive parts, are the plain
/// output of `darkbloom cluster console --plain`.
enum ClusterConsoleContent {
    /// Lines of session output shown; the export keeps more.
    static let shownSessionOutput = 8
    static let shownActivity = 6

    static func body(_ state: ClusterConsoleState) -> [ClusterConsoleLine] {
        guard let snapshot = state.snapshot else {
            return [.init("Reading this Mac's link, saved setup and session state.", .dim, indent: 0)]
        }
        if state.showsHelp { return help() }
        let status = state.status ?? snapshot.diagnostics
        return readiness(snapshot, status: status, state: state) + [.blank]
            + pairing(snapshot, interactive: true) + [.blank]
            + model(snapshot, status: status) + [.blank]
            + session(status: status, state: state) + [.blank]
            + activity(state) + [.blank]
            + [.heading("Not available in this build"),
               .init(ClusterConsoleWiring.unavailable.map(\.title).joined(separator: "; ") + ". Press ? for the reasons.", .dim)]
    }

    /// The whole state as text for a pipe or a log: no keys, no scrolling.
    static func plain(_ snapshot: ClusterConsoleSnapshot) -> [String] {
        let state = ClusterConsoleState(size: .init(columns: 0, rows: 0), options: .init(onboarding: false))
        let lines = readiness(snapshot, status: snapshot.diagnostics, state: state, interactive: false) + [.blank]
            + pairing(snapshot, interactive: false) + [.blank]
            + model(snapshot, status: snapshot.diagnostics) + [.blank]
            + liveSession(snapshot.diagnostics, heading: "Session") + [.blank]
            + [.heading("Not available in this build")]
            + ClusterConsoleWiring.unavailable.map { .init("\($0.title): \($0.reason)") }
        return lines.map { String(repeating: " ", count: $0.indent) + $0.text }
    }

    // MARK: - Readiness

    static func readiness(_ snapshot: ClusterConsoleSnapshot, status: ClusterDiagnosticsReport, state: ClusterConsoleState,
                          interactive: Bool = true) -> [ClusterConsoleLine] {
        let link = snapshot.link
        var lines = [ClusterConsoleLine.heading("Readiness: link \(link.state.rawValue)")]
        // The guided setup's own sentences. Its "Next:" line tells a pipe what
        // to run; on the screen the next step is a key, said below.
        for line in snapshot.setup.lines where !interactive || !line.hasPrefix("Next: ") {
            lines.append(.init(line, link.state == .ready ? .good : .normal))
        }
        if interactive {
            switch snapshot.setup.next {
            case .awaitConnection:
                lines.append(.init("Watching for a connection: the link is read again every \(ClusterLinkWatch.pollIntervalSeconds) seconds.", .warning))
            case .fix where state.inFlight == .fixLink:
                lines.append(.init(state.options.dryRun ? "Dry run: working out what the fix would ask for."
                    : "macOS was asked to approve the address. Answer its prompt.", .warning))
            case .fix:
                lines.append(.init("Press f to give that port an address. macOS asks for your approval; nothing changes without it.", .warning))
            case .ready, .stopped:
                break
            }
        }
        let active = link.devices.filter(\.portActive), idle = link.devices.filter { !$0.portActive }
        for device in active { lines.append(.init(device.summary, device.verdict == .ready ? .good : .warning, indent: 4)) }
        if !idle.isEmpty {
            lines.append(.init("\(idle.count) port\(idle.count == 1 ? "" : "s") down: " + idle.map(\.device).joined(separator: ", "), .dim, indent: 4))
        }
        for alias in snapshot.aliases {
            switch alias.presence {
            case .present: lines.append(.init("The address Darkbloom added to \(alias.interface) is still on that port.", .normal))
            case .gone: lines.append(.init("The address Darkbloom added to \(alias.interface) is no longer on that port. It does not survive a restart or a replug.", .warning))
            case .unknown: lines.append(.init("Darkbloom recorded an address on \(alias.interface); whether it is still there could not be read.", .warning))
            }
        }
        if let installed = snapshot.saved.installed {
            lines.append(worker(installed))
        }
        lines.append(journal(status.deviceJournal))
        lines.append(.init("Checks, as `darkbloom cluster doctor` reports them:", .dim))
        for check in snapshot.diagnostics.checks {
            lines.append(.init("[\(check.outcome.rawValue)] \(check.name): \(check.detail)", style(check.outcome), indent: 4))
        }
        return lines
    }

    private static func worker(_ installed: ClusterConsoleInstalled) -> ClusterConsoleLine {
        guard installed.workerBinary.verified else {
            return .init("Worker binary: not verified. \(installed.workerBinary.detail ?? "")", .bad)
        }
        let guardText: String
        switch installed.hasProgressGuard {
        case true?: guardText = "progress guard present"
        case false?: guardText = "NO progress guard, so a start is refused"
        case nil: guardText = "progress guard not read"
        }
        let deadline = installed.acceptsStartupDeadline == true ? "startup deadline accepted" : "no startup deadline"
        return .init("Worker binary: matches its pin; \(guardText); \(deadline).", installed.hasProgressGuard == true ? .good : .bad)
    }

    private static func journal(_ journal: ClusterDeviceJournalObservation) -> ClusterConsoleLine {
        switch journal {
        case .absent: return .init("Device journal: absent.", .normal)
        case .emptyJournal: return .init("Device journal: empty.", .normal)
        case .ownershipUnproven:
            return .init("Device journal: names a session. A start is refused until its owner clears it or `c` recovers it.", .warning)
        case .unsafeOrChanging:
            return .init("Device journal: could not be read safely (it changed, or its file or directory is not owner-only).", .bad)
        }
    }

    private static func style(_ outcome: ClusterDiagnosticsReport.Outcome) -> ClusterConsoleLine.Style {
        switch outcome {
        case .passed: return .good
        case .failed: return .bad
        case .notRun, .notObserved: return .dim
        }
    }

    // MARK: - Pairing and trust

    static func pairing(_ snapshot: ClusterConsoleSnapshot, interactive: Bool) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading("Pairing and trust")]
        switch snapshot.saved.state {
        case .notConfigured:
            lines.append(.init("No cluster setup is saved on this Mac. Nothing is paired and no peer is trusted."))
        case .unreadable:
            lines.append(.init("The saved setup cannot be read: \(snapshot.saved.error ?? "")", .bad))
        case .loaded:
            if let pairing = snapshot.saved.pairing { lines += describe(pairing, saved: true) }
        }
        if let candidate = snapshot.candidate {
            lines.append(.init("Setup passed in for approval:", .heading))
            if let error = candidate.error {
                lines.append(.init("It cannot be read as a setup: \(error)", .bad, indent: 4))
            } else if let pairing = candidate.pairing {
                lines += describe(pairing, saved: false).map { .init($0.text, $0.style, indent: 4) }
                lines.append(.init("Model: \(candidate.publicModelID ?? "") as \(candidate.runtimeModelID ?? "").", indent: 4))
                if candidate.alreadySaved {
                    lines.append(.init("This is the setup already saved.", .good, indent: 4))
                } else if interactive {
                    lines.append(.init("Not saved and not trusted. Press a, then y, to approve it; any other key leaves it unapproved.", .warning, indent: 4))
                } else {
                    lines.append(.init("Not saved and not trusted. `darkbloom cluster configure`, or `a` in the console, approves it.", .warning, indent: 4))
                }
            }
        }
        return lines
    }

    private static func describe(_ pairing: ClusterConsolePairing, saved: Bool) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine("Cluster \(pairing.clusterID): this Mac is \(pairing.memberID) (\(pairing.role.rawValue), rank \(pairing.localRank)) on \(pairing.linkDevice); the peer is \(pairing.peerID) (rank \(pairing.peerRank)).")]
        let trust = pairing.trust
        if trust.hostKeys.isEmpty {
            lines.append(.init("Peer host key: none could be read from the pinned known-hosts file.", .warning))
        }
        for key in trust.hostKeys { lines.append(.init("Peer host key: \(key.algorithm) \(key.fingerprint)")) }
        switch trust.knownHostsPinMatches {
        case true?: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file still matches it.", .good))
        case false?: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file no longer matches it. \(saved ? "A start is refused until the setup is approved again." : "It cannot be approved as it is.")", .bad))
        case nil: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file could not be read.", .bad))
        }
        lines.append(trust.identityFileUsable ? .init("Identity file: present and owner-only.", .good)
            : .init("Identity file: missing, or not an owner-only regular file.", .bad))
        if let error = trust.error { lines.append(.init(error, .bad)) }
        if let approval = pairing.pairApproval {
            lines.append(.init("Coordinator pair approval \(approval.id), generation \(approval.generation), for \(approval.model) on \(approval.allowedChips.joined(separator: ", ")), until \(approval.notAfter). A saved expectation: only the coordinator's own file approves a pair."))
        } else {
            lines.append(.init("Coordinator pair approval: none saved.", .dim))
        }
        return lines
    }

    // MARK: - Model

    static func model(_ snapshot: ClusterConsoleSnapshot, status: ClusterDiagnosticsReport) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading("Model")]
        let admitted = snapshot.admittedModels.map { "\($0.runtimeModelID) (\($0.adapterID) v\($0.adapterVersion))" }
        lines.append(.init("This build admits across two Macs: " + (admitted.isEmpty ? "nothing" : admitted.joined(separator: ", ")) + "."))
        guard let model = snapshot.saved.model else {
            lines.append(.init("No model is selected: a model is chosen by the saved setup, and none is saved.", .dim))
            return lines
        }
        lines.append(.init("Saved setup serves \(model.publicModelID) as \(model.runtimeModelID): artifact \(ClusterConsoleText.short(model.artifactSHA256)), Plan \(ClusterConsoleText.short(model.planSHA256)), \(model.prefillSchedule) prefill, at most \(model.maximumRequests) requests and \(model.maximumLifetimeSeconds) seconds per session."))
        let members = status.live?.session.members ?? []
        for stage in model.stages {
            let count = stage.sourceLayerEnd - stage.sourceLayerStart
            var text = "Rank \(stage.rank), \(stage.peerID)\(stage.local ? " (this Mac)" : ""): layers \(stage.sourceLayerStart) to \(stage.sourceLayerEnd - 1) (\(count))."
            var style = ClusterConsoleLine.Style.normal
            if let member = members.first(where: { $0.rank == stage.rank }) {
                if member.nativeReady, let capacity = member.requestCapacityBytes {
                    text += " Admitted and loaded; request capacity \(bytes(Int64(capacity)))."
                    style = .good
                } else {
                    text += " Not ready."
                    style = .warning
                }
            }
            lines.append(.init(text, style, indent: 4))
        }
        if members.isEmpty {
            lines.append(.init("Per-rank admission: not observed. A worker admits when it loads, and no session is being served.", .dim))
        }
        if let installed = snapshot.saved.installed {
            if !installed.manifest.verified {
                lines.append(.init("Model directory on this Mac: its manifest is not verified. \(installed.manifest.detail ?? "")", .bad))
            } else if let files = installed.artifactFiles {
                let complete = files.present == files.expected
                lines.append(.init("Model directory on this Mac: \(files.present) of \(files.expected) manifest files present with the manifest's sizes (\(bytes(files.expectedBytes)) in all)."
                    + (complete ? "" : " Missing or different: \(files.missingOrDifferent.joined(separator: ", "))."), complete ? .good : .bad))
                lines.append(.init("Weight contents are verified by the worker as it loads them, not here.", .dim))
            }
        }
        return lines
    }

    // MARK: - Session

    static func session(status: ClusterDiagnosticsReport, state: ClusterConsoleState) -> [ClusterConsoleLine] {
        var lines = liveSession(status, heading: "Session")
        switch state.session {
        case .none: lines.insert(.init("No session was started from this screen."), at: 1)
        case .launching: lines.insert(.init("Starting `darkbloom start --local --distributed`.", .warning), at: 1)
        case .running(let identifier):
            lines.insert(.init("Process \(identifier), started from this screen, is running.", .good), at: 1)
        case .stopping(let identifier):
            lines.insert(.init("Process \(identifier) was asked to stop and has not ended.", .warning), at: 1)
        case .ended(let description):
            lines.insert(.init("The session process started from this screen \(description)."), at: 1)
        }
        if !state.sessionOutput.isEmpty {
            lines.append(.init("Its output, last lines:", .dim))
            for line in state.sessionOutput.suffix(shownSessionOutput) { lines.append(.init(line, .dim, indent: 4)) }
        }
        return lines
    }

    /// The leader's own report, field for field as `cluster status` prints it.
    static func liveSession(_ status: ClusterDiagnosticsReport, heading: String) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading(heading)]
        guard let live = status.live else {
            let reason = status.checks.first { $0.name == "localServingObservation" }?.detail
            lines.append(.init("Local leader: not observed." + (reason.map { " \($0)" } ?? ""), .dim))
            return lines
        }
        lines.append(.init("Local leader: host \(live.hostPhase), session \(live.session.phase), \(live.ready ? "ready" : "not ready"), admission \(live.admissionAvailable ? "available" : "closed"), port \(live.boundPort), \(live.authenticationConfigured ? "bearer authentication" : "no authentication").",
            live.ready ? .good : .warning))
        lines.append(.init("Epoch \(live.session.observedMembershipEpoch ?? "not observed"); native bootstrap \(live.session.nativeBootstrap.rawValue)\(live.session.nativeBootstrapOwnerAuthenticated ? "" : " (the peer that answers is not authenticated)"); collective progress limit \(live.session.collectiveProgressLimitMilliseconds) ms."))
        if let admission = live.session.admission {
            lines.append(.init("Lifetime remaining \(admission.remainingLifetimeNanoseconds / 1_000_000_000) s; admissions remaining \(admission.remainingRequests); \(admission.activeRequest ? "a request is active" : "no active request")\(admission.draining ? "; draining" : "")."))
        }
        for member in live.session.members {
            var text = "Rank \(member.rank), \(member.peerID): \(member.transport.rawValue); native \(member.nativeReady ? "ready" : "not ready"); cleanup \(member.nativeCleanupObserved ? "observed" : "not observed"); release \(member.ownerReleaseAcknowledged ? "acknowledged" : "not acknowledged")"
            if let termination = member.ownerTermination {
                text += "; owner \(termination.kind.rawValue)" + (termination.status.map { " \($0)" } ?? "")
            }
            lines.append(.init(text + ".", member.nativeReady ? .good : .warning, indent: 4))
        }
        if live.quarantined { lines.append(.init("Quarantined: an owner has not released its device.", .bad)) }
        return lines
    }

    // MARK: - Activity and help

    static func activity(_ state: ClusterConsoleState) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading("Activity")]
        if state.activity.isEmpty { lines.append(.init("Nothing has been run from this screen.", .dim)) }
        for entry in state.activity.suffix(shownActivity) {
            lines.append(.init("\(entry.time) \(entry.title)", entry.failed ? .bad : .good))
            for line in entry.lines { lines.append(.init(line, entry.failed ? .bad : .normal, indent: 4)) }
        }
        return lines
    }

    static func help() -> [ClusterConsoleLine] {
        var lines: [ClusterConsoleLine] = [.heading("Keys"),
            .init("r  read everything again"),
            .init("f  fix link: give the active port an address; macOS asks for approval"),
            .init("a  approve the setup passed in, then y to confirm"),
            .init("s  start the distributed session on both Macs, then y to confirm"),
            .init("x  stop the session this screen started"),
            .init("c  recover: clear a journal whose owner and worker are gone"),
            .init("e  export a redacted diagnostics file into the current directory"),
            .init("up, down, page up, page down, home, end  scroll;  ?  this page;  q or Ctrl-C  close"),
            .blank, .heading("Not available in this build")]
        for item in ClusterConsoleWiring.unavailable {
            lines.append(.init("\(item.title): \(item.reason)", item.exists ? .normal : .dim))
        }
        return lines
    }

    static func bytes(_ count: Int64) -> String {
        let gibibyte = 1_073_741_824.0, mebibyte = 1_048_576.0
        return Double(count) >= gibibyte ? String(format: "%.1f GiB", Double(count) / gibibyte)
            : String(format: "%.1f MiB", Double(count) / mebibyte)
    }
}

extension ClusterConsoleSnapshot {
    /// The snapshot as text for a pipe or a log, section by section.
    public var plainLines: [String] { ClusterConsoleContent.plain(self) }
}
