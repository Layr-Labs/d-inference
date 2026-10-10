import Foundation

/// One line of the screen before it is fitted to a width.
public struct ClusterConsoleLine: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case title, heading, normal, good, warning, bad, dim, prompt }

    /// Where a line's words come from. A line that states something about
    /// this Mac names the row of `handoff/TUI-wiring.md` it was read from, and
    /// a check holds every such row to the wired list; a line cannot be built
    /// without saying which it is.
    public enum Source: Equatable, Sendable {
        /// A wired element, by its identifier.
        case wired(String)
        /// The screen's own furniture: headings, keys, questions, and the
        /// list of what this build cannot do.
        case frame
    }

    public let text: String
    public let style: Style
    /// Leading columns, kept when the line wraps.
    public let indent: Int
    public let source: Source

    init(_ text: String, _ style: Style = .normal, indent: Int = 2, from source: Source) {
        self.text = text; self.style = style; self.indent = indent; self.source = source
    }

    static func heading(_ text: String) -> ClusterConsoleLine { .init(text, .heading, indent: 0, from: .frame) }
    static let blank = ClusterConsoleLine("", .normal, indent: 0, from: .frame)
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
            return [.init("Reading this Mac's link, saved setup and session state.", .dim, indent: 0, from: .frame)]
        }
        if state.showsHelp { return help() }
        let status = state.status ?? snapshot.diagnostics
        return readiness(snapshot, status: status, state: state) + [.blank]
            + pairing(snapshot, interactive: true) + [.blank]
            + model(snapshot, status: status) + [.blank]
            + session(status: status, state: state) + [.blank]
            + activity(state) + [.blank]
            + [.heading("Not available in this build"),
               .init(ClusterConsoleWiring.unavailable.map(\.title).joined(separator: "; ") + ". Press ? for the reasons.", .dim, from: .frame)]
    }

    /// The whole state as text for a pipe or a log: no keys, no scrolling.
    static func plain(_ snapshot: ClusterConsoleSnapshot) -> [String] {
        let state = ClusterConsoleState(size: .init(columns: 0, rows: 0), options: .init(onboarding: false))
        let lines = readiness(snapshot, status: snapshot.diagnostics, state: state, interactive: false) + [.blank]
            + pairing(snapshot, interactive: false) + [.blank]
            + model(snapshot, status: snapshot.diagnostics) + [.blank]
            + liveSession(snapshot.diagnostics, heading: "Session") + [.blank]
            + [.heading("Not available in this build")]
            + ClusterConsoleWiring.unavailable.map { .init("\($0.title): \($0.reason)", from: .frame) }
        return lines.map { String(repeating: " ", count: $0.indent) + $0.text }
    }

    // MARK: - Readiness

    static func readiness(_ snapshot: ClusterConsoleSnapshot, status: ClusterDiagnosticsReport, state: ClusterConsoleState,
                          interactive: Bool = true) -> [ClusterConsoleLine] {
        let link = snapshot.link
        var lines = [ClusterConsoleLine("Readiness: link \(link.state.rawValue)", .heading, indent: 0, from: .wired("link.rdma"))]
        // The guided setup's own sentences. Its "Next:" line tells a pipe what
        // to run; on the screen the next step is a key, said below.
        for line in snapshot.setup.lines where !interactive || !line.hasPrefix("Next: ") {
            lines.append(.init(line, link.state == .ready ? .good : .normal, from: .wired("link.narration")))
        }
        if interactive {
            lines += linkStep(snapshot, state: state)
        } else if snapshot.setup.next == .awaitKeeper {
            lines.append(.init("Nothing is waited for here: run this again in a few seconds to see whether the address is back.", from: .frame))
        }
        let active = link.devices.filter(\.portActive), idle = link.devices.filter { !$0.portActive }
        for device in active { lines.append(.init(device.summary, device.verdict == .ready ? .good : .warning, indent: 4, from: .wired("link.port"))) }
        if !idle.isEmpty {
            lines.append(.init("\(idle.count) port\(idle.count == 1 ? "" : "s") down: " + idle.map(\.device).joined(separator: ", "), .dim, indent: 4, from: .wired("link.port")))
        }
        lines += link.devices.compactMap(assignedAddress)
        if let installed = snapshot.saved.installed { lines.append(worker(installed)) }
        lines.append(journal(status.deviceJournal))
        lines.append(.init("Checks, as `darkbloom cluster doctor` reports them:", .dim, from: .frame))
        for check in snapshot.diagnostics.checks {
            lines.append(.init("[\(check.outcome.rawValue)] \(check.name): \(check.detail)", style(check.outcome), indent: 4, from: .wired("doctor.checks")))
        }
        return lines
    }

    /// What the screen is doing about the link, or which key does it.
    private static func linkStep(_ snapshot: ClusterConsoleSnapshot, state: ClusterConsoleState) -> [ClusterConsoleLine] {
        let next = snapshot.setup.next, options = state.options
        let reread = "the link is read again every \(ClusterLinkWatch.pollIntervalSeconds) seconds"
        if next == .awaitConnection {
            return [.init("Watching for a connection: \(reread).", .warning, from: .wired("link.wait"))]
        }
        guard next == .fix || next == .awaitKeeper else { return [] }
        if state.inFlight == .fixLink {
            return [.init(options.dryRun ? "Dry run: working out what an approval would run. Nothing is asked or changed."
                : "The link fix is running. If it asks, macOS shows its own prompt: approve or cancel it there.", .warning, from: .wired("link.fix"))]
        }
        let approval = "macOS asks for your approval; nothing changes without it."
        if next == .awaitKeeper {
            // The reducer asks for the fix once the system job has had its readings, if it still may.
            let automatic = state.mayStartLinkFixUnasked && snapshot.setup.fixDevice != nil
            let byKey = options.dryRun ? "Press f for a dry run of the fix."
                : options.temporary ? "Press f to put it there now. \(approval)"
                : "Press f to put it there now and install its system job afresh. \(approval)"
            return [.init("Watching for the address: \(reread). " + (automatic
                ? "If it is not back after \(ClusterConsoleLinkSetup.keeperReadings) readings, the fix is asked for once\(options.dryRun ? ", as a dry run." : " and macOS shows its prompt.")"
                : byKey), .warning, from: .wired("link.wait"))]
        }
        let fix: String
        let fixPort = snapshot.link.devices.first { $0.device == snapshot.setup.fixDevice }
        if options.dryRun {
            fix = "Press f for a dry run of the fix: it lists the commands an approval would run, and changes nothing."
        } else if !options.temporary, fixPort?.isolationApplies == true {
            // Link setup v2: the port gets its own network service, ready or not.
            fix = "Press f to give that port its own network service with a fixed address, no router and no DNS, outside every bridge, which macOS keeps there. \(approval)"
        } else if snapshot.link.state == .ready {
            // A ready port is offered a fix only because nothing keeps its address.
            fix = "Press f to install the system job that keeps that address there. \(approval)"
        } else if options.temporary {
            fix = "Press f to give that port an address that lasts until macOS next removes it. \(approval)"
        } else {
            fix = "Press f to give that port an address and install the system job that keeps it there. \(approval)"
        }
        return [.init(fix, .warning, from: .wired("link.fix"))]
    }

    /// For a port Darkbloom has on record: whether it carries the address
    /// assigned to it, and whether the system job that keeps it is loaded.
    /// Nil for a port with no such record.
    private static func assignedAddress(_ device: ClusterLinkReadinessReport.Device) -> ClusterConsoleLine? {
        guard let assigned = device.assignedAddress else { return nil }
        let port = device.interface ?? device.device, source = ClusterConsoleLine.Source.wired("link.alias")
        let seconds = ClusterLinkAddressKeeper.intervalSeconds
        switch (assigned, device.addressKept) {
        case (.present, true?):
            return .init("\(port) carries the address Darkbloom assigned to it, and the system job that keeps it is installed and loaded.", .good, from: source)
        case (.present, false?):
            return .init("\(port) carries the address Darkbloom assigned to it, and no system job keeps it: macOS removes it when it next reconfigures the port.", .warning, from: source)
        case (.present, nil):
            return .init("\(port) carries the address Darkbloom assigned to it; whether its system job is loaded could not be read.", .warning, from: source)
        case (.missing, true?):
            return .init("\(port) does not carry the address Darkbloom has on record for it; its system job is loaded and runs every \(seconds) seconds.", .warning, from: source)
        case (.missing, false?):
            return .init("\(port) does not carry the address Darkbloom has on record for it, and no system job would put it back.", .warning, from: source)
        case (.missing, nil):
            return .init("\(port) does not carry the address Darkbloom has on record for it; whether its system job is loaded could not be read.", .warning, from: source)
        }
    }

    private static func worker(_ installed: ClusterConsoleInstalled) -> ClusterConsoleLine {
        guard installed.workerBinary.verified else {
            return .init("Worker binary: not verified. \(installed.workerBinary.detail ?? "")", .bad, from: .wired("installed.worker"))
        }
        let guardText: String
        switch installed.hasProgressGuard {
        case true?: guardText = "progress guard present"
        case false?: guardText = "NO progress guard, so a start is refused"
        case nil: guardText = "progress guard not read"
        }
        let deadline = installed.acceptsStartupDeadline == true ? "startup deadline accepted" : "no startup deadline"
        return .init("Worker binary: matches its pin; \(guardText); \(deadline).", installed.hasProgressGuard == true ? .good : .bad,
            from: .wired("installed.worker"))
    }

    private static func journal(_ journal: ClusterDeviceJournalObservation) -> ClusterConsoleLine {
        let source = ClusterConsoleLine.Source.wired("journal.state")
        switch journal {
        case .absent: return .init("Device journal: absent.", from: source)
        case .emptyJournal: return .init("Device journal: empty.", from: source)
        case .ownershipUnproven:
            return .init("Device journal: not empty. A session is using this Mac's device or left its journal behind; a start is refused until its owner clears it or `c` recovers it.", .warning, from: source)
        case .unsafeOrChanging:
            return .init("Device journal: could not be read safely (it changed, or its file or directory is not owner-only).", .bad, from: source)
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
            lines.append(.init("No cluster setup is saved on this Mac. Nothing is paired and no peer is trusted.", from: .wired("pair.saved")))
        case .unreadable:
            lines.append(.init("The saved setup cannot be read: \(snapshot.saved.error ?? "")", .bad, from: .wired("pair.saved")))
        case .loaded:
            if let pairing = snapshot.saved.pairing { lines += describe(pairing, saved: true) }
        }
        if let candidate = snapshot.candidate {
            let source = ClusterConsoleLine.Source.wired("pair.approve")
            lines.append(.init("Setup passed in for approval:", .heading, from: source))
            if let error = candidate.error {
                lines.append(.init("It cannot be read as a setup: \(error)", .bad, indent: 4, from: source))
            } else if let pairing = candidate.pairing {
                lines += describe(pairing, saved: false).map { .init($0.text, $0.style, indent: 4, from: $0.source) }
                lines.append(.init("Model: \(candidate.publicModelID ?? "") as \(candidate.runtimeModelID ?? ""); setup \(ClusterConsoleText.short(candidate.configurationSHA256 ?? "")).", indent: 4, from: source))
                if candidate.alreadySaved {
                    lines.append(.init("This is the setup already saved.", .good, indent: 4, from: source))
                } else if interactive {
                    lines.append(.init("Not saved and not trusted. Press a, then y, to approve it; any other key leaves it unapproved.", .warning, indent: 4, from: source))
                } else {
                    lines.append(.init("Not saved and not trusted. `darkbloom cluster configure`, or `a` in the console, approves it.", .warning, indent: 4, from: source))
                }
            }
        }
        return lines
    }

    private static func describe(_ pairing: ClusterConsolePairing, saved: Bool) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine("Cluster \(pairing.clusterID): this Mac is \(pairing.memberID) (\(pairing.role.rawValue), rank \(pairing.localRank)) on \(pairing.linkDevice); the peer is \(pairing.peerID) (rank \(pairing.peerRank)).",
            from: .wired("pair.saved"))]
        let trust = pairing.trust, keys = ClusterConsoleLine.Source.wired("pair.hostkey")
        if trust.hostKeys.isEmpty {
            lines.append(.init("Pinned known-hosts file: no key could be read from it.", .warning, from: keys))
        }
        for key in trust.hostKeys {
            switch key.kind {
            case .host: lines.append(.init("Pinned host key: \(key.algorithm) \(key.fingerprint)", from: keys))
            case .certificateAuthority: lines.append(.init("Pinned certificate authority, whose signed host keys are accepted: \(key.algorithm) \(key.fingerprint)", .warning, from: keys))
            case .revoked: lines.append(.init("Pinned as revoked, and refused: \(key.algorithm) \(key.fingerprint)", .dim, from: keys))
            }
        }
        if trust.hostKeysNotShown > 0 {
            lines.append(.init("\(trust.hostKeysNotShown) more key\(trust.hostKeysNotShown == 1 ? "" : "s") in the pinned file \(trust.hostKeysNotShown == 1 ? "is" : "are") not listed here.", .warning, from: keys))
        }
        switch trust.knownHostsPinMatches {
        case true?: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file still matches it.", .good, from: keys))
        case false?: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file no longer matches it. \(saved ? "A start is refused until the setup is approved again." : "It cannot be approved as it is.")", .bad, from: keys))
        case nil: lines.append(.init("Known-hosts pin \(ClusterConsoleText.short(trust.knownHostsPinSHA256)): the file could not be read.", .bad, from: keys))
        }
        let identity = ClusterConsoleLine.Source.wired("pair.identity")
        lines.append(trust.identityFileUsable ? .init("Identity file: present and owner-only.", .good, from: identity)
            : .init("Identity file: missing, or not an owner-only regular file.", .bad, from: identity))
        if let error = trust.error { lines.append(.init(error, .bad, from: identity)) }
        if let approval = pairing.pairApproval {
            lines.append(.init("Coordinator pair approval \(approval.id), generation \(approval.generation), for \(approval.model) on \(approval.allowedChips.joined(separator: ", ")), until \(approval.notAfter). A saved expectation: only the coordinator's own file approves a pair.", from: .wired("pair.approval")))
        } else {
            lines.append(.init("Coordinator pair approval: none saved.", .dim, from: .wired("pair.approval")))
        }
        return lines
    }

    // MARK: - Model

    static func model(_ snapshot: ClusterConsoleSnapshot, status: ClusterDiagnosticsReport) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading("Model")]
        let admitted = snapshot.admittedModels.map { "\($0.runtimeModelID) (\($0.adapterID) v\($0.adapterVersion))" }
        lines.append(.init("The cluster runtime in this build accepts a setup for: " + (admitted.isEmpty ? "nothing" : admitted.joined(separator: ", "))
            + ". A start also applies its own model and chip checks.", from: .wired("model.admitted")))
        guard let model = snapshot.saved.model else {
            lines.append(.init("No model is selected: a model is chosen by the saved setup, and none is read.", .dim, from: .wired("model.saved")))
            return lines
        }
        lines.append(.init("Saved setup serves \(model.publicModelID) as \(model.runtimeModelID): artifact \(ClusterConsoleText.short(model.artifactSHA256)), Plan \(ClusterConsoleText.short(model.planSHA256)), \(model.prefillSchedule) prefill, at most \(model.maximumRequests) requests and \(model.maximumLifetimeSeconds) seconds per session.", from: .wired("model.saved")))
        let members = status.live?.session.members ?? []
        for stage in model.stages {
            let count = stage.sourceLayerEnd - stage.sourceLayerStart
            lines.append(.init("Rank \(stage.rank), \(stage.peerID)\(stage.local ? " (this Mac)" : ""): layers \(stage.sourceLayerStart) to \(stage.sourceLayerEnd - 1) (\(count)).", indent: 4, from: .wired("model.ranks")))
        }
        // The plan's figure from the model's own files, beside this Mac's size:
        // a small share on a large Mac is the plan and not a sign of nothing running.
        if let holdings = snapshot.saved.installed?.holdings {
            lines.append(.init(holdings.line, holdings.holdings == nil ? .dim : .normal, indent: 4, from: .wired("model.holdings")))
        }
        for member in members {
            if member.nativeReady {
                let capacity = member.requestCapacityBytes.map { "request capacity \(bytes(Int64($0)))" } ?? "no request capacity reported"
                lines.append(.init("Rank \(member.rank), \(member.peerID): admitted and loaded, by the leader's status; \(capacity).", .good, indent: 4, from: .wired("model.admission")))
            } else {
                lines.append(.init("Rank \(member.rank), \(member.peerID): not ready, by the leader's status.", .warning, indent: 4, from: .wired("model.admission")))
            }
        }
        if members.isEmpty {
            lines.append(.init(status.live == nil
                ? "Per-rank admission: not observed. A worker admits as it loads, and the leader's status, which reports it, was not read."
                : "Per-rank admission: not observed. The leader's status names no member yet.", .dim, from: .wired("model.admission")))
        }
        if let installed = snapshot.saved.installed {
            if !installed.manifest.verified {
                lines.append(.init("Model directory on this Mac: its manifest is not verified. \(installed.manifest.detail ?? "")", .bad, from: .wired("model.metadata")))
            } else if let files = installed.artifactFiles {
                let complete = files.present == files.expected
                lines.append(.init("Model directory on this Mac: \(files.present) of \(files.expected) manifest files present with the manifest's sizes (\(bytes(files.expectedBytes)) in all)."
                    + (complete ? "" : " Missing or different: \(files.missingOrDifferent.joined(separator: ", "))."), complete ? .good : .bad, from: .wired("model.files")))
                lines.append(.init("Weight contents are verified by the worker as it loads them, not here.", .dim, from: .frame))
            }
        }
        return lines
    }

    // MARK: - Session

    static func session(status: ClusterDiagnosticsReport, state: ClusterConsoleState) -> [ClusterConsoleLine] {
        var lines = liveSession(status, heading: "Session")
        let process = ClusterConsoleLine.Source.wired("session.process")
        switch state.session {
        case .none: lines.insert(.init("No session was started from this screen.", from: process), at: 1)
        case .launching: lines.insert(.init("Starting `darkbloom start --local --distributed`.", .warning, from: process), at: 1)
        case .running(let identifier):
            lines.insert(.init("Process \(identifier), started from this screen, is running.", .good, from: process), at: 1)
        case .stopping(let identifier):
            lines.insert(.init("Process \(identifier) was asked to stop and has not ended.", .warning, from: process), at: 1)
        case .ended(let description):
            lines.insert(.init("The session process started from this screen \(description).", from: process), at: 1)
        }
        if !state.sessionOutput.isEmpty {
            lines.append(.init("Its output, last lines:", .dim, from: .frame))
            for line in state.sessionOutput.suffix(shownSessionOutput) { lines.append(.init(line, .dim, indent: 4, from: process)) }
        }
        return lines
    }

    /// The leader's own report, field for field as `cluster status` prints it.
    static func liveSession(_ status: ClusterDiagnosticsReport, heading: String) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading(heading)]
        let source = ClusterConsoleLine.Source.wired("session.status")
        guard let live = status.live else {
            let reason = status.checks.first { $0.name == "localServingObservation" }?.detail
            lines.append(.init("Local leader: not observed." + (reason.map { " \($0)" } ?? ""), .dim, from: source))
            return lines
        }
        lines.append(.init("Local leader: host \(live.hostPhase), session \(live.session.phase), \(live.ready ? "ready" : "not ready"), admission \(live.admissionAvailable ? "available" : "closed"), port \(live.boundPort), \(live.authenticationConfigured ? "bearer authentication" : "no authentication").",
            live.ready ? .good : .warning, from: .wired("host.local")))
        lines.append(.init("Epoch \(live.session.observedMembershipEpoch ?? "not observed"); native bootstrap \(live.session.nativeBootstrap.rawValue)\(live.session.nativeBootstrapOwnerAuthenticated ? "" : " (the peer that answers is not authenticated)"); collective progress limit \(live.session.collectiveProgressLimitMilliseconds) ms.", from: source))
        if let admission = live.session.admission {
            lines.append(.init("Lifetime remaining \(admission.remainingLifetimeNanoseconds / 1_000_000_000) s; admissions remaining \(admission.remainingRequests); \(admission.activeRequest ? "a request is active" : "no active request")\(admission.draining ? "; draining" : "").", from: source))
        }
        for member in live.session.members {
            var text = "Rank \(member.rank), \(member.peerID): \(member.transport.rawValue); native \(member.nativeReady ? "ready" : "not ready"); cleanup \(member.nativeCleanupObserved ? "observed" : "not observed"); release \(member.ownerReleaseAcknowledged ? "acknowledged" : "not acknowledged")"
            if let termination = member.ownerTermination {
                text += "; owner \(termination.kind.rawValue)" + (termination.status.map { " \($0)" } ?? "")
            }
            lines.append(.init(text + ".", member.nativeReady ? .good : .warning, indent: 4, from: source))
        }
        if live.quarantined { lines.append(.init("Quarantined: an owner has not released its device.", .bad, from: source)) }
        return lines
    }

    // MARK: - Activity and help

    /// What was run from this screen and what each operation reported.
    static func activity(_ state: ClusterConsoleState) -> [ClusterConsoleLine] {
        var lines = [ClusterConsoleLine.heading("Activity")]
        if state.activity.isEmpty {
            lines.append(.init(state.inFlight.map { "\($0.title) is running and has not reported yet." } ?? "Nothing has been run from this screen.",
                .dim, from: .frame))
        }
        for entry in state.activity.suffix(shownActivity) {
            let source = ClusterConsoleAction.allCases.first { $0.title == entry.title }.map { ClusterConsoleLine.Source.wired($0.wiring) }
                ?? .wired("session.process")
            lines.append(.init("\(entry.time) \(entry.title)", entry.failed ? .bad : .good, from: source))
            for line in entry.lines { lines.append(.init(line, entry.failed ? .bad : .normal, indent: 4, from: source)) }
        }
        return lines
    }

    static func help() -> [ClusterConsoleLine] {
        var lines: [ClusterConsoleLine] = [.heading("Keys"),
            .init("r  read everything again", from: .frame),
            .init("f  fix link: give the active port an address and keep it there; macOS asks for approval", from: .frame),
            .init("a  approve the setup passed in, then y to confirm", from: .frame),
            .init("s  start the distributed session on both Macs, then y to confirm", from: .frame),
            .init("x  stop the session this screen started", from: .frame),
            .init("c  recover: clear a journal whose owner and worker are gone, then y to confirm", from: .frame),
            .init("e  export a redacted diagnostics file into the current directory", from: .frame),
            .init("up, down, page up, page down, home, end  scroll;  ?  this page;  q or Ctrl-C  close", from: .frame),
            .blank, .heading("Not available in this build")]
        for item in ClusterConsoleWiring.unavailable {
            lines.append(.init("\(item.title): \(item.reason)", item.exists ? .normal : .dim, from: .frame))
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
