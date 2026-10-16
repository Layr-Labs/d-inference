import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// What each step says, from the state alone: what was detected, what is
/// wrong in plain words, and the one action that fixes it. Every line that
/// states something names the wired row it was read from.
enum ClusterSetupContent {
    typealias Line = ClusterSetupFrame.Line
    typealias Span = ClusterSetupFrame.Span
    typealias Style = ClusterSetupFrame.Style

    /// Lines built for one width.
    struct Builder {
        let width: Int
        let glyphs: ClusterSetupGlyphs
        let interactive: Bool
        var lines = [Line]()
        static let labelColumn = 15

        mutating func heading(_ text: String) { lines.append(.init(" " + text, .heading, from: .frame)) }
        mutating func blank() { if lines.last?.text.isEmpty == false { lines.append(.blank) } }

        /// Wrapped prose, indented.
        mutating func text(_ text: String, _ style: Style = .normal, indent: Int = 3, from source: ClusterConsoleLine.Source) {
            for row in ClusterSetupScreen.wrap(text, width: width - indent, hanging: 0) {
                lines.append(.init([.init(String(repeating: " ", count: indent)), .init(row, style)], from: source))
            }
        }

        /// A mark, then wrapped prose beside it.
        mutating func verdict(_ mark: String, _ text: String, _ style: Style, from source: ClusterConsoleLine.Source) {
            let rows = ClusterSetupScreen.wrap(text, width: width - 5, hanging: 0)
            for (index, row) in rows.enumerated() {
                lines.append(.init([.init(index == 0 ? " \(mark) " : "   ", style), .init(" " + row, index == 0 ? style : style)], from: source))
            }
        }

        /// A label column, then the value wrapped under itself.
        mutating func fact(_ label: String, _ value: String, _ style: Style = .normal, from source: ClusterConsoleLine.Source) {
            let column = Self.labelColumn
            let rows = ClusterSetupScreen.wrap(value, width: width - column - 3, hanging: 0)
            for (index, row) in rows.enumerated() {
                let left = index == 0 ? "   " + label.padding(toLength: column, withPad: " ", startingAt: 0) : String(repeating: " ", count: column + 3)
                lines.append(.init([.init(left, .dim), .init(row, style)], from: source))
            }
        }

        mutating func row(_ spans: [Span], from source: ClusterConsoleLine.Source) { lines.append(.init(spans, from: source)) }

        /// A key and what it does, as the step's one action.
        mutating func action(_ key: String, _ text: String, enabled: Bool = true, from source: ClusterConsoleLine.Source) {
            guard interactive else {
                self.text(text, .accent, from: source)
                return
            }
            let rows = ClusterSetupScreen.wrap(text, width: width - 6 - key.count, hanging: 0)
            for (index, row) in rows.enumerated() {
                let lead: [Span] = index == 0 ? [.init("   "), .init(" \(key) ", enabled ? .selected : .dim), .init(" ")]
                    : [.init(String(repeating: " ", count: 6 + key.count))]
                lines.append(.init(lead + [.init(row, enabled ? .accent : .dim)], from: source))
            }
        }
    }

    // MARK: - Body

    static func body(_ state: ClusterSetupState, width: Int, glyphs: ClusterSetupGlyphs, interactive: Bool) -> [Line] {
        var b = Builder(width: width, glyphs: glyphs, interactive: interactive)
        guard let local = state.snapshot?.local else {
            b.text("Reading this Mac: chip, memory, disk, the cable and the saved setup.", .dim, from: .frame)
            return b.lines
        }
        switch state.step {
        case .thisMac: thisMac(state, local, &b)
        case .cable: cable(state, local, &b)
        case .pair: pairing(state, local, &b)
        case .model: model(state, local, &b)
        case .check: check(state, local, &b)
        case .serve: serve(state, local, &b)
        }
        return b.lines
    }

    // MARK: 1 This Mac

    static func thisMac(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let mac = local.mac, profile = mac.profile, g = b.glyphs
        b.heading("Detected")
        var chip = mac.chip
        if let profile {
            chip += " \u{B7} \(profile.performanceCores + profile.efficiencyCores) CPU cores (\(profile.performanceCores) performance, \(profile.efficiencyCores) efficiency)"
            if let gpu = profile.gpuCores { chip += " \u{B7} \(gpu) GPU cores" }
        }
        b.fact("Chip", chip, from: .wired("mac.profile"))
        var memory = ClusterSetupScreen.gib(mac.physicalMemoryBytes)
        if let profile {
            memory += " \u{B7} the GPU may keep \(ClusterSetupScreen.gib(profile.gpuRecommendedWorkingSetBytes)) resident \u{B7} \(ClusterSetupScreen.gib(profile.memory.admissibleNowBytes)) free for a model now"
        }
        b.fact("Memory", memory, from: .wired("mac.profile"))
        if let free = mac.diskFreeBytes {
            b.fact("Disk", "\(ClusterSetupScreen.gib(free)) free" + (mac.diskTotalBytes.map { " of \(ClusterSetupScreen.gib($0))" } ?? "") + " on the models volume",
                free < 20 * 1_073_741_824 ? .warning : .normal, from: .wired("mac.disk"))
        } else {
            b.fact("Disk", "free space not read", .dim, from: .wired("mac.disk"))
        }
        b.fact("macOS", mac.osVersion + (mac.osSupportsRDMA ? "" : " (RDMA needs 26.2 or later)"), mac.osSupportsRDMA ? .normal : .bad, from: .wired("mac.profile"))
        let rdma = local.link.rdmaDisabled ? ("turned off", Style.bad) : local.link.rdmaUnavailable ? ("not available on this Mac", .bad) : ("enabled", .good)
        b.fact("RDMA", rdma.0, rdma.1, from: .wired("link.rdma"))
        if let power = profile?.power {
            var parts = [power.onExternalPower ? "on power" : "on battery"]
            parts.append(power.lowPowerMode ? "Low Power Mode on" : "Low Power Mode off")
            parts.append("thermal \(power.thermalState)")
            b.fact("Power", parts.joined(separator: " \u{B7} "), power.admitsExecution ? .normal : .warning, from: .wired("mac.profile"))
        }
        b.fact("Left wired", leftWired(local.memoryGuard), local.memoryGuard.decision == .refused ? .bad : .normal, from: .wired("session.cleanup"))
        b.fact("Darkbloom", local.version, from: .wired("mac.version"))
        b.blank()

        var problems = 0
        if local.link.rdmaDisabled {
            problems += 1
            b.verdict(g.blocked, "RDMA over Thunderbolt is turned off. macOS lets you turn it on only from Recovery, and Darkbloom never changes it for you:", .bad, from: .wired("link.rdma"))
            for (index, step) in recoverySteps.enumerated() { b.text("\(index + 1). \(step)", indent: 6, from: .frame) }
        } else if local.link.rdmaUnavailable {
            problems += 1
            b.verdict(g.blocked, mac.osSupportsRDMA
                ? "This Mac lists no RDMA device. RDMA over Thunderbolt needs a Mac with Thunderbolt 5; this one cannot join a cluster over RDMA."
                : "This macOS has no RDMA over Thunderbolt. Update to macOS 26.2 or later in System Settings, General, Software Update, then run `darkbloom cluster` again.",
                .bad, from: .wired("link.rdma"))
        } else if !mac.osSupportsRDMA {
            problems += 1
            b.verdict(g.blocked, "RDMA over Thunderbolt needs macOS 26.2 or later. Update in System Settings, General, Software Update.", .bad, from: .wired("mac.profile"))
        }
        if local.memoryGuard.decision == .refused {
            problems += 1
            b.verdict(g.blocked, "\(local.memoryGuard.detail ?? "Memory is wired that no process holds.")", .bad, from: .wired("session.cleanup"))
        }
        if let power = profile?.power, !power.admitsExecution {
            b.verdict("!", powerAdvice(power), .warning, from: .wired("mac.profile"))
        }
        if mac.profile == nil {
            if mac.profileError == ClusterSetupLocalReader.noWorkerYet {
                b.text("The memory a model can use is read by the plan tool beside the worker, once a setup names this Mac's worker.", .dim, from: .wired("mac.profile"))
            } else {
                b.verdict("!", "Memory figures are the system's own: the plan tool beside the worker did not answer (\(mac.profileError ?? "not installed")). Step 4 needs it to plan.", .warning, from: .wired("mac.profile"))
            }
        }
        if let free = mac.diskFreeBytes, free < 20 * 1_073_741_824 {
            b.verdict("!", "Little disk space is left. A model needs its full size free on both Macs before it can be copied.", .warning, from: .wired("mac.disk"))
        }
        if problems == 0 {
            b.verdict(g.done, "This Mac can join a cluster.", .good, from: .wired("link.rdma"))
            b.action("enter", "Next: the cable", from: .frame)
        } else {
            b.action("r", "Read again after the change", from: .frame)
        }
    }

    /// The Recovery steps for `rdma_ctl enable`, which only an administrator at the Mac can run.
    static let recoverySteps = [
        "Choose Apple menu, Shut Down, and wait until the Mac is off.",
        "Press and hold the power button until \u{201C}Loading startup options\u{201D} appears.",
        "Click Options, then Continue. Sign in as an administrator if asked.",
        "Choose Utilities, Terminal.",
        "Type  rdma_ctl enable  and press Return.",
        "Choose Apple menu, Restart.",
        "Run `darkbloom cluster` again: it opens here and checks again.",
    ]

    static func powerAdvice(_ power: ClusterDevicePower) -> String {
        if !power.onExternalPower { return "Connect this Mac to power: requests are refused while it runs on battery." }
        if power.lowPowerMode { return "Turn off Low Power Mode in System Settings, Battery: requests are refused while it is on." }
        return "This Mac is hot (thermal \(power.thermalState)): requests are refused until it cools down."
    }

    static func leftWired(_ reading: ClusterSetupMemoryGuard, whose: String = "this Mac's") -> String {
        guard let wired = reading.wiredBytes else { return "wired memory not read" }
        let baseline = reading.baselineBytes.map(ClusterSetupScreen.gib) ?? "?"
        switch reading.decision {
        case .clear: return "nothing: \(ClusterSetupScreen.gib(wired)) wired, under \(whose) \(baseline) idle baseline"
        case .refused: return "\(ClusterSetupScreen.gib(wired)) wired with no Darkbloom process running, above the \(baseline) idle baseline"
        case .skipped: return "\(ClusterSetupScreen.gib(wired)) wired; not compared, \(reading.detail ?? "a Darkbloom process runs")"
        }
    }

    // MARK: 2 Cable

    static func cable(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let link = local.link, g = b.glyphs
        // What the person just asked for comes first.
        switch state.linkFix {
        case .previewed(let result), .applied(let result):
            linkFixResult(state, result, &b)
            b.blank()
        case .previewing, .applying, .idle: break
        }
        b.heading("Detected")
        if let port = link.port {
            var facts = [String]()
            facts.append(port.verdict == ClusterLinkReadinessState.ready.rawValue ? "ready" : "not ready (\(port.verdict))")
            if port.hasIPv4Address == true { facts.append("own address") } else if port.hasIPv4Address == false { facts.append("no address") }
            if port.gidPublished == true { facts.append("RDMA address published") }
            if let bridge = port.bridge { facts.append("in \(bridge)") }
            let name = (port.interface ?? port.device) + (port.hardwarePort.map { " (\u{201C}\($0)\u{201D})" } ?? "")
            b.fact("Cluster port", "\(name) \u{B7} " + facts.joined(separator: ", "), port.verdict == "ready" ? .good : .warning, from: .wired("link.port"))
        } else {
            b.fact("Cluster port", "none active (\(link.portsDown) RDMA port\(link.portsDown == 1 ? "" : "s") down)", .warning, from: .wired("link.port"))
        }
        if let connection = link.clusterConnection {
            b.fact("Connection", connectionWords(connection), connection.generation == .thunderbolt5 ? .good : .bad, from: .wired("link.thunderbolt"))
        } else if let error = link.thunderboltError {
            b.fact("Connection", "Thunderbolt not read: \(error)", .dim, from: .wired("link.thunderbolt"))
        }
        if let thunderbolt = link.thunderbolt {
            let cluster = link.clusterConnection?.id
            let others = thunderbolt.receptacles.filter { $0.connected && $0.id != cluster }
            let idle = thunderbolt.receptacles.filter { !$0.connected }
            var parts = others.map { "\(connectionWords($0)) on port \($0.id)" }
            if !idle.isEmpty {
                let fast = idle.filter(\.portIsThunderbolt5).map { String($0.id) }
                parts.append("\(idle.count) idle" + (fast.isEmpty ? "" : " (Thunderbolt 5: \(fast.joined(separator: ", ")))"))
            }
            if !parts.isEmpty { b.fact("Other ports", parts.joined(separator: "; "), .dim, from: .wired("link.thunderbolt")) }
        }
        if let port = link.port, let isolated = port.isolated {
            let findings = port.findings.compactMap(ClusterLinkIsolationFinding.init(rawValue:))
            let words = isolated ? "the cable carries cluster traffic only" : "shared: " + findings.map { $0.fact(interface: port.interface ?? port.device, bridge: port.bridge) }.joined(separator: "; ")
            b.fact("Isolation", words, isolated ? .good : .warning, from: .wired("link.isolation"))
        }
        b.blank()


        if link.ready {
            if let port = link.port, port.isolated == false {
                if port.blockers.isEmpty {
                    b.verdict(g.done, "The cable works, so setup can go on. Recommended: give the port to the cluster alone, so macOS or Internet Sharing cannot take its address in the middle of a session.", .good, from: .wired("link.isolation"))
                    b.action("f", "Fix link (one approval): first shows the exact commands; nothing changes until you approve", enabled: !state.session.isActive, from: .wired("link.fix"))
                } else {
                    b.verdict(g.done, "The cable works, so setup can go on. The port is not isolated, and the fix cannot run yet:", .good, from: .wired("link.isolation"))
                    b.text(port.isolationGuidance ?? "Something outside Darkbloom's reach is in the way.", .warning, indent: 6, from: .wired("link.isolation"))
                }
            } else {
                b.verdict(g.done, "The cable is ready.", .good, from: .wired("link.port"))
            }
            b.action("enter", "Next: pair with the other Mac", from: .frame)
            return
        }
        if link.state == ClusterLinkReadinessState.noActivePort.rawValue {
            b.verdict(g.waiting, "No Thunderbolt RDMA port is active. Connect the two Macs directly with a Thunderbolt 5 cable: no dock, no hub. This screen reads the link again every few seconds.", .warning, from: .wired("link.port"))
            return
        }
        if link.clusterConnection?.generation == .thunderbolt4 {
            b.verdict(g.blocked, "This connection runs at 40 Gb/s: a Thunderbolt 4 or USB4 port or cable is in the path. RDMA needs Thunderbolt 5 at both ends and a Thunderbolt 5 cable. Move the cable to a Thunderbolt 5 port on each Mac.", .bad, from: .wired("link.thunderbolt"))
            return
        }
        if link.rdmaDisabled || link.rdmaUnavailable {
            b.verdict(g.blocked, "RDMA is not available on this Mac yet: step 1 says what to do.", .bad, from: .wired("link.rdma"))
            return
        }
        b.verdict(g.blocked, link.port?.isolationGuidance ?? link.guidance ?? "The cable is not usable yet (\(link.state)).", .warning, from: .wired("link.port"))
        b.action("f", "Fix link (one approval): first shows the exact commands; nothing changes until you approve", enabled: !state.session.isActive, from: .wired("link.fix"))
    }

    static func connectionWords(_ receptacle: ClusterSetupThunderbolt.Receptacle) -> String {
        let peer = [receptacle.peerName, receptacle.peerModel].compactMap { $0 }
        let to = peer.isEmpty ? "" : " to " + (peer.count == 2 ? "\(peer[0]) (\(peer[1]))" : peer[0])
        switch receptacle.generation {
        case .thunderbolt5?: return "Thunderbolt 5 at \(receptacle.speed)\(to)"
        case .thunderbolt4?: return "Thunderbolt 4 or USB4 at \(receptacle.speed)\(to): no RDMA"
        case .slower?: return "\(receptacle.speed)\(to): too slow for RDMA"
        case nil: return "nothing connected"
        }
    }

    static func linkFixResult(_ state: ClusterSetupState, _ result: ClusterSetupLinkFixResult, _ b: inout Builder) {
        let g = b.glyphs
        if result.dryRun, result.outcome == "dryRun" {
            b.heading("Fix link: the exact commands")
            b.text(state.options.dryRun ? "Dry run: these are the commands an approval would run. This screen applies nothing."
                : "If you approve, macOS asks once for an administrator, then Darkbloom runs exactly:", .dim, from: .wired("link.fix"))
            for (index, command) in result.commands.enumerated() {
                b.text("\(String(index + 1).padding(toLength: 3, withPad: " ", startingAt: 0)) \(command)", indent: 4, from: .wired("link.fix"))
            }
            return
        }
        b.heading(result.dryRun ? "Fix link: preview" : "Fix link: result")
        b.verdict(result.succeeded ? g.done : g.blocked, linkFixWords(result), result.succeeded ? .good : .bad, from: .wired("link.fix"))
        // The operation's own sentences, less its first line, which names the outcome by its code.
        let detail = result.lines.first?.hasPrefix("Link fix:") == true ? Array(result.lines.dropFirst()) : result.lines
        for line in detail { b.text(line, indent: 6, from: .wired("link.fix")) }
    }

    /// The fix's outcome in plain words.
    static func linkFixWords(_ result: ClusterSetupLinkFixResult) -> String {
        switch result.outcome {
        case "alreadyReady": return "Nothing to fix: the port is already set up for the cluster."
        case "fixed": return "Fixed: the port belongs to the cluster now, and macOS keeps its address."
        case "isolationRefused": return "The fix cannot run yet; nothing was changed."
        case "nothingFixable": return "This is not something the fix can cure; nothing was changed."
        case "approvalDeclined": return "The macOS prompt was cancelled; nothing was changed."
        case "approvalUnavailable": return "macOS could not show its prompt here; nothing was changed. `darkbloom cluster link --fix` on this Mac's own screen shows it."
        case "appliedButNotIsolated", "appliedButNotReady": return "Approved, but the port is not as it should be yet."
        case "commandFailed": return "Approved, but a command failed."
        default: return result.lines.first ?? result.outcome
        }
    }

    // MARK: 3 Pair

    static func pairing(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let g = b.glyphs
        guard let pair = state.pair else {
            if let error = state.snapshot?.pairError {
                b.verdict(g.blocked, state.linkPaired ? "Paired, but step 4 cannot plan from this Mac yet: \(error)"
                    : "The pair description given to this wizard cannot be read: \(error)", .bad, from: .wired("pair.saved"))
            } else {
                b.verdict(g.waiting, "This Mac does not know the other Mac yet.", .warning, from: .wired("pair.saved"))
            }
            b.blank()
            // No SSH in the user path (owner gate 2026-10-11): pairing is the
            // ceremony over the link; no host-key code, no pair description.
            linkPairing(state, &b)
            b.blank()
            b.heading("What to do")
            b.text("Run `darkbloom cluster` on both Macs and press l on each: they find each other on the cable, both screens show the same six digits, and you type y on each Mac. Nothing else to type.", from: .frame)
            if state.linkPaired {
                b.text("Paired: step 4 takes the model and the plan. Press r to look again.", from: .frame)
            }
            return
        }
        b.heading("Pair")
        let role = pair.leads.map { $0 ? "this Mac leads" : "this Mac follows" } ?? "who leads comes from the plan in step 4"
        b.fact("Cluster", "\(pair.clusterID) \u{B7} this Mac: \(pair.localMemberID) \u{B7} the other Mac: \(pair.peerMemberID)", from: .wired("pair.saved"))
        // Paired over the link (S17): the other Mac is reached over the paired link, never SSH, and no host-key code applies.
        let overLink = state.linkPaired && (pair.source == .description || state.savedSetup?.overLink == true)
        b.fact("From", (overLink && pair.source == .description ? "the pairing over the link" : sourceWords(pair.source)) + " \u{B7} " + role,
            from: .wired("pair.saved"))
        b.blank()

        if pair.canReachPeer, overLink {
            b.heading("The other Mac")
            switch state.peer {
            case .unknown:
                b.text("Not reached yet.", .dim, from: .wired("pair.verify"))
                b.action("p", "Reach it over the paired link", from: .wired("pair.verify"))
            case .reaching(let since):
                b.text("\(g.spin(state.now)) Reaching it over the paired link\u{2026} \(seconds(state.now, since))", .accent, from: .wired("pair.verify"))
            case .failed(let reason):
                b.verdict(g.blocked, "Could not reach the other Mac over the paired link: \(reason)", .bad, from: .wired("pair.verify"))
                b.text("Open `darkbloom cluster` on the other Mac too: its open wizard answers over the cable. No address and no SSH are needed.", indent: 6, from: .frame)
                b.action("p", "Try again", from: .wired("pair.verify"))
            case .reached(let report, let seconds, _):
                b.verdict(g.done, String(format: "Answered over the paired link in %.2f s, authenticated by the pairing's key.", seconds), .good, from: .wired("pair.verify"))
                b.fact("Other Mac", peerWords(report), from: .wired("peer.report"))
            }
            b.blank()
            linkPairing(state, &b)
            b.blank()
            b.action("enter", "Next: model and plan (paired over the link)", from: .frame)
            return
        }

        if pair.canReachPeer {
            b.heading("The other Mac")
            switch state.peer {
            case .unknown:
                b.text("Not reached yet.", .dim, from: .wired("pair.verify"))
                b.action("p", "Reach it over the pinned route", from: .wired("pair.verify"))
            case .reaching(let since):
                b.text("\(g.spin(state.now)) Reaching it over the pinned route\u{2026} \(seconds(state.now, since))", .accent, from: .wired("pair.verify"))
            case .failed(let reason):
                b.verdict(g.blocked, "Could not reach \(pair.peerMemberID) over the pinned route: \(reason)", .bad, from: .wired("pair.verify"))
                b.text("Check that the cable is in and the other Mac is awake, then run `darkbloom cluster` on both Macs again.", indent: 6, from: .frame)
                b.action("p", "Try again", from: .wired("pair.verify"))
            case .reached(let report, let seconds, _):
                b.verdict(g.done, String(format: "Answered over the pinned route in %.2f s: it holds the host key the setup pins.", seconds), .good, from: .wired("pair.verify"))
                b.fact("Other Mac", peerWords(report), from: .wired("peer.report"))
            }
            b.blank()
        }

        b.heading("Pairing code")
        if let code = state.pairingCode {
            let reachedFirst = pair.canReachPeer && state.peerReport == nil
            if reachedFirst {
                b.text("The code shows once the other Mac has answered over the pinned route.", .dim, from: .wired("pair.code"))
            } else {
                b.row([.init("      "), .init(" \(code.spaced) ", .selected)], from: .wired("pair.code"))
                b.text(pair.canReachPeer ? "On the other Mac run `darkbloom cluster`: its step 3 shows the code of its own host key. Both must be the same."
                    : "This is the code of this Mac's own host key. The leader's screen shows the code of the Mac it reached; both must be the same.",
                    from: .wired("pair.code"))
                if code.differsFromPin {
                    b.verdict(g.blocked, "This Mac's own host key is not the one its setup pins. Do not approve anything until that is explained.", .bad, from: .wired("pair.code"))
                }
            }
            if let confirmed = state.record.confirmed(code: code.code) {
                let at = confirmed.at
                b.verdict(g.done, "Confirmed\(at.isEmpty ? "" : " \(at)"): both screens showed this code.", .good, from: .wired("pair.confirm"))
                b.action("enter", "Next: model and plan", from: .frame)
            } else if state.linkPaired {
                b.action("enter", "Next: model and plan (paired over the link)", from: .frame)
            } else if !reachedFirst {
                b.action("enter", "Both screens show \(code.spaced)", from: .wired("pair.confirm"))
            }
        } else {
            b.text(pair.canReachPeer ? "No code yet: the other Mac has not answered over the cable." : "No code yet: run `darkbloom cluster` on the other Mac too.", .warning, from: .wired("pair.code"))
        }
        b.blank()
        linkPairing(state, &b)
    }

    /// The pairing ceremony over the Thunderbolt link (S17): no SSH, a code on
    /// both screens, each Mac pinning the other's attested Secure Enclave key.
    static func linkPairing(_ state: ClusterSetupState, _ b: inout Builder) {
        let g = b.glyphs
        b.heading("Pair over the link (no SSH)")
        for pairing in state.local?.linkPairings?.pairings ?? [] {
            b.verdict(g.done, "Paired with \(pairing.peerName): its Secure Enclave key \(pairing.peerPin)\u{2026} is pinned; roster \(pairing.clusterID), generation \(pairing.generation).",
                .good, from: .wired("pair.link"))
        }
        if let error = state.local?.linkPairings?.error {
            b.verdict(g.blocked, "The pairing store cannot be trusted: \(error)", .bad, from: .wired("pair.link"))
        }
        switch state.linkPairing {
        case .idle, .finished:
            if case .finished(let succeeded, let lines) = state.linkPairing {
                if let first = lines.first { b.verdict(succeeded ? g.done : g.blocked, first, succeeded ? .good : .bad, from: .wired("pair.link")) }
                for line in lines.dropFirst() { b.text(line, indent: 6, from: .wired("pair.link")) }
            }
            if !state.linkPaired {
                b.text("Each Mac pins the other's attested Secure Enclave key. Both screens show one code; nothing to type but y or n.", from: .wired("pair.link"))
            }
            b.action("l", state.linkPaired ? "Pair again: press l on both Macs" : "Pair: press l on both Macs; each finds the other on the cable", from: .wired("pair.link"))
            b.action("c", "Connect to an address the other Mac shows (only if finding it fails)", from: .wired("pair.link"))
        case .enteringAddress(let text):
            b.row([.init("      Other Mac's address: "), .init(" \(text)_ ", .selected)], from: .wired("pair.link"))
            b.text("enter: dial it \u{B7} escape: cancel", .dim, indent: 6, from: .frame)
        case .waiting(let text):
            b.text("\(g.spin(state.now)) \(text)", .accent, from: .wired("pair.link"))
        case .code(let code, let peer):
            b.row([.init("      "), .init(" \(code.prefix(3)) \(code.suffix(3)) ", .selected)], from: .wired("pair.link"))
            for line in peer { b.text(line, indent: 6, from: .wired("pair.link")) }
            b.text("Compare it with the other Mac's screen: y if both show it, n if not.", from: .wired("pair.link"))
        case .confirmedHere(let peerConfirmed):
            b.text(peerConfirmed ? "\(g.spin(state.now)) Both Macs confirmed; storing the pins and the roster\u{2026}"
                : "\(g.spin(state.now)) Confirmed here; waiting for the other Mac\u{2026}", .accent, from: .wired("pair.link"))
        }
    }

    static func sourceWords(_ source: ClusterSetupPair.Source) -> String {
        switch source {
        case .saved: return "the saved setup"
        case .inbox: return "the setup the leader sent"
        case .description: return "the pair description"
        }
    }

    static func peerWords(_ report: ClusterSetupReport) -> String {
        var parts = [report.mac.chip, ClusterSetupScreen.gib(report.mac.physicalMemoryBytes), "macOS \(report.mac.osVersion)"]
        if report.link.ready {
            parts.append("cable ready" + (report.link.clusterConnection.map { " (\(connectionWords($0)))" } ?? ""))
        } else {
            parts.append("cable not ready (\(report.link.state))")
        }
        parts.append("Darkbloom \(report.version)")
        return parts.joined(separator: " \u{B7} ")
    }

    /// How long a starting session may go without status before the reason is shown.
    static let statusGraceNanoseconds: UInt64 = 45_000_000_000

    static func seconds(_ now: UInt64, _ since: UInt64) -> String {
        guard now >= since else { return "" }
        return String(format: "%.0f s", Double(now - since) / 1e9)
    }

    // MARK: 4 Model

    static func model(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let g = b.glyphs
        if let inbox = local.inbox, local.saved.setup?.configurationSHA256 != inbox.configurationSHA256 {
            b.heading("Setup sent by \(inbox.peerID)")
            setupFacts(inbox, &b, source: "pair.inbox")
            b.text("Saving it trusts the pinned host key and the plan above. Nothing starts.", .dim, from: .frame)
            b.action("a", "Approve this setup", from: .wired("pair.approve"))
            if let error = local.inboxError { b.verdict(g.blocked, error, .bad, from: .wired("pair.inbox")) }
            return
        }
        if let saved = local.saved.setup, state.pair?.clusterID == saved.clusterID {
            b.heading("Saved setup")
            setupFacts(saved, &b, source: "pair.saved")
            if saved.isLeader {
                switch state.peerHasItsSetup {
                case true?: b.verdict(g.done, "The other Mac has saved its matching setup.", .good, from: .wired("peer.report"))
                case false?:
                    b.verdict(g.waiting, "The other Mac has not saved its setup yet. On it, run `darkbloom cluster`: step 4 shows the setup this Mac sent; press a, then y.", .warning, from: .wired("peer.report"))
                    b.action("p", "Look again", from: .wired("pair.verify"))
                case nil:
                    b.text("The other Mac's setup is checked when it answers.", .dim, from: .wired("peer.report"))
                }
            }
            // A saved setup is replaced only from a fresh plan, which r makes.
            guard state.mayPlan, case .ready(let options) = state.plans else {
                if state.status(of: .model) == .done { b.action("enter", saved.isLeader ? "Next: the check" : "Next", from: .frame) }
                guard state.mayPlan, saved.isLeader else { return }
                if state.replanRequested || state.plans == .planning {
                    b.text("\(g.spin(state.now)) Planning each model from both Macs' memory now\u{2026}", .accent, from: .wired("model.plan"))
                } else if case .failed(let reason) = state.plans {
                    b.verdict(g.blocked, "Planning failed: \(reason)", .bad, from: .wired("model.plan"))
                    b.action("r", "Plan again", from: .wired("model.plan"))
                } else {
                    b.text("To serve another model, press r: it plans again from both Macs' memory now.", .dim, from: .wired("model.plan"))
                }
                return
            }
            b.blank()
            modelList(state, options, &b)
            return
        }
        guard state.mayPlan else {
            b.verdict(g.waiting, state.pair == nil ? (state.linkPaired && state.snapshot?.pairError != nil
                ? "Paired, but this Mac cannot plan yet: \(state.snapshot?.pairError ?? "")" : "Pair first: step 3.") : "Waiting for the leader to send this Mac its setup. Run `darkbloom cluster` on the leader; press r here to look again.", .warning, from: .wired("pair.inbox"))
            return
        }
        guard state.peerReport != nil else {
            b.verdict(g.waiting, "Planning needs the other Mac's memory: reach it in step 3 first.", .warning, from: .wired("pair.verify"))
            return
        }
        switch state.plans {
        case .notRun:
            b.text("Not planned yet.", .dim, from: .wired("model.plan"))
        case .planning:
            b.text("\(g.spin(state.now)) Planning each model from both Macs' memory\u{2026}", .accent, from: .wired("model.plan"))
        case .failed(let reason):
            b.verdict(g.blocked, "Planning failed: \(reason)", .bad, from: .wired("model.plan"))
            b.action("r", "Plan again", from: .wired("model.plan"))
        case .ready(let options):
            modelList(state, options, &b)
        }
    }

    static func setupFacts(_ setup: ClusterSetupSetupSummary, _ b: inout Builder, source: String) {
        b.fact("Model", setup.publicModelID, from: .wired(source))
        let stages = setup.stages.map { "\($0.memberID)\($0.memberID == setup.memberID ? " (this Mac)" : "") layers \($0.firstLayer)-\($0.endLayer - 1)" }
        b.fact("Split", stages.joined(separator: " \u{B7} "), from: .wired(source))
        b.fact("Mode", (setup.generationMode.isEmpty ? "pipeline_v1" : setup.generationMode) + " \u{B7} \(setup.prefillSchedule) prefill", from: .wired(source))
        b.fact("Role", setup.isLeader ? "this Mac leads (rank 0): it starts serving" : "this Mac follows (rank \(setup.localRank)): the leader starts it", from: .wired(source))
        if let holds = setup.holdings { b.fact("Holds", holds, .dim, from: .wired(source)) }
        b.fact("Setup", String(setup.configurationSHA256.prefix(12)), .dim, from: .wired(source))
    }

    static func modelList(_ state: ClusterSetupState, _ options: [ClusterSetupModelOption], _ b: inout Builder) {
        let g = b.glyphs
        guard !options.isEmpty else {
            b.verdict(g.blocked, "No model folder was found beside this Mac's model directory.", .bad, from: .wired("model.inventory"))
            return
        }
        b.heading("Models")
        let nameWidth = min(28, max(12, options.map { displayName($0.model).count }.max() ?? 12))
        for (index, option) in options.enumerated() {
            let selected = index == state.selectedModel
            let name = String(displayName(option.model).prefix(nameWidth)).padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let size = ClusterSetupScreen.gib(Int(clamping: option.model.totalBytes)).padding(toLength: 9, withPad: " ", startingAt: 0)
            var tail: [Span]
            if let blocker = option.blocker {
                tail = [.init(shortBlocker(blocker), .dim)]
            } else if let plan = option.plan {
                tail = [.init(plan.fitsNow ? "fits now" : "needs \(ClusterSetupScreen.gib(plan.needsBytes ?? 0)) more", plan.fitsNow ? .good : .warning),
                        .init(plan.absolute ? String(format: "  first token %@ \u{B7} %.0f tok/s", time(plan.firstTokenSeconds), plan.decodeTokensPerSecond)
                            : "  speed not measured", .dim)]
            } else {
                tail = []
            }
            let mark = selected ? g.selected : " "
            let style: Style = option.blocker == nil ? (selected ? .title : .normal) : .dim
            b.row([.init(" \(mark) ", selected ? .accent : .normal), .init(name, style), .init(" " + size, .dim)] + tail, from: .wired(option.blocker == nil ? "model.plan" : "model.inventory"))
        }
        guard options.indices.contains(state.selectedModel) else { return }
        let option = options[state.selectedModel]
        b.blank()
        if let blocker = option.blocker {
            b.verdict(g.blocked, "\(displayName(option.model)): \(blocker)", .warning, from: .wired("model.inventory"))
            return
        }
        guard let plan = option.plan else { return }
        let total = plan.ranks.last?.endLayer ?? 0
        b.heading("\(displayName(option.model)): \(plan.leaderID == state.pair?.localMemberID ? "this Mac leads" : "\(plan.leaderID) leads")")
        b.fact("Plan", "cut after \(plan.cut) of \(total) layers \u{B7} \(plan.mode) \u{B7} \(plan.prefillSchedule) prefill", from: .wired("model.plan"))
        let barWidth = max(8, min(20, b.width - 62))
        for rank in plan.ranks {
            let who = rank.memberID + (rank.local ? " (this Mac)" : "")
            let bar = ClusterSetupScreen.bar(rank.needBytes, of: max(rank.admissibleNowBytes, 1), width: barWidth, glyphs: g)
            let fits = rank.fit == "now"
            b.row([.init("   "), .init(who.padding(toLength: 18, withPad: " ", startingAt: 0), .normal),
                   .init("layers \(rank.firstLayer)-\(rank.endLayer - 1)".padding(toLength: 14, withPad: " ", startingAt: 0), .dim),
                   .init(bar, fits ? .good : .bad),
                   .init(" \(ClusterSetupScreen.gib(rank.needBytes)) of \(ClusterSetupScreen.gib(rank.admissibleNowBytes)) free", fits ? .normal : .bad)],
                  from: .wired("model.plan"))
            if !fits { b.text(rank.fitDetail, .warning, indent: 6, from: .wired("model.plan")) }
        }
        if plan.absolute {
            let label = plan.measured ? "" : " (estimate)"
            b.fact("Predicted", String(format: "at %@ prompt tokens: first token %@, decode %.0f tok/s%@", grouped(plan.promptTokens),
                time(plan.firstTokenSeconds), plan.decodeTokensPerSecond, label), from: .wired("model.plan"))
        } else {
            b.fact("Predicted", "speed was not measured for this model on these Macs, so the split follows memory; no time is shown", .dim, from: .wired("model.plan"))
        }
        let alone = plan.alone.map { a in
            guard a.holds else { return "\(a.memberID) cannot hold it" }
            guard plan.absolute else { return "\(a.memberID) holds it" + (a.fitsNow ? "" : " (not now)") }
            return String(format: "%@ %@ / %.0f tok/s", a.memberID, time(a.firstTokenSeconds), a.decodeTokensPerSecond) + (a.fitsNow ? "" : " (not now)")
        }
        if !alone.isEmpty { b.fact("Each alone", alone.joined(separator: " \u{B7} "), .dim, from: .wired("model.plan")) }
        if !plan.aloneAsFast.isEmpty {
            b.text("\(plan.aloneAsFast.joined(separator: " and ")) alone would be as fast for this request; the pair still splits memory.", .dim, from: .wired("model.plan"))
        }
        b.action("enter", "Use this plan: save it here and send the other Mac its setup", enabled: state.pairingConfirmed, from: .wired("model.adopt"))
        if !state.pairingConfirmed { b.text("Confirm the pairing code in step 3 first.", .warning, indent: 6, from: .frame) }
    }

    /// A model's name without its publisher, as a list shows it.
    static func displayName(_ model: ClusterSetupLocalModel) -> String {
        model.modelID.split(separator: "/").last.map(String.init) ?? model.modelID
    }

    /// The reason a model cannot be chosen, short enough for its row; the full one shows when it is selected.
    static func shortBlocker(_ blocker: String) -> String {
        if blocker == ClusterSetupPlanning.notClusterModel { return blocker }
        if blocker == ClusterSetupPlanning.differentBuilds { return "different Darkbloom builds" }
        if blocker.hasPrefix("not on ") { return "not on the other Mac" }
        if blocker.hasPrefix("too large") { return "too large for this pair" }
        if blocker.contains("holds it alone") { return "one Mac holds it alone" }
        return String(blocker.prefix(30))
    }

    static func time(_ seconds: Double) -> String { seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds) }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: 5 Check

    static func check(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let g = b.glyphs
        guard let saved = local.saved.setup else {
            b.verdict(g.waiting, "There is no saved setup to check yet: step 4.", .warning, from: .wired("pair.saved"))
            return
        }
        guard saved.isLeader else {
            b.verdict(g.done, "This Mac follows: the leader runs the check, and this Mac's worker takes part in it.", .good, from: .wired("pair.saved"))
            b.fact("Device", "journal \(ClusterSetupState.journalWords(local.journal))", from: .wired("journal.state"))
            b.action("enter", "Next", from: .frame)
            return
        }
        b.text("Loads \(saved.publicModelID) on both Macs, waits for both ranks, sends \(ClusterSetupState.checkTokens) tokens through the local API, stops, and checks that both Macs released their memory.", .dim, from: .frame)
        b.blank()
        let current: ClusterSetupState.CheckStage?, failedAt: ClusterSetupState.CheckStage?
        switch state.check {
        case .running(let stage, _): current = stage; failedAt = nil
        case .failed(let stage, _): current = nil; failedAt = stage
        case .idle, .passed: current = nil; failedAt = nil
        }
        let passed: Bool = { if case .passed = state.check { return true }; return false }()
        for stage in ClusterSetupState.CheckStage.allCases {
            let mark: String, style: Style
            var detail = ""
            if passed || (current.map { stage < $0 } ?? false) || (failedAt.map { stage < $0 } ?? false) {
                (mark, style) = (g.done, .good)
            } else if stage == current {
                (mark, style) = (g.spin(state.now), .accent)
            } else if stage == failedAt {
                (mark, style) = (g.blocked, .bad)
            } else {
                (mark, style) = (g.todo, .dim)
            }
            switch stage {
            case .ranks:
                if stage == current || passed || (failedAt.map { stage <= $0 } ?? false) {
                    detail = "\(passed ? 2 : state.checkReadyRanks) of 2 ranks ready"
                    if let ready = state.checkReadySeconds { detail += String(format: " in %.1f s", ready) }
                    else if case .running(.ranks, let since) = state.check { detail += " \u{B7} " + seconds(state.now, since) }
                }
            case .generate:
                if let result = state.checkPrompt {
                    var parts = ["\(result.completionTokens) tokens"]
                    if let first = result.firstTokenMilliseconds { parts.append(String(format: "first token %.2f s", Double(first) / 1000)) }
                    if let rate = result.tokensPerSecond { parts.append(String(format: "%.0f tok/s", rate)) }
                    detail = parts.joined(separator: " \u{B7} ")
                }
            case .start:
                if case .running(let pid, _) = state.session, current.map({ $0 >= .start }) == true { detail = "process \(pid)" }
            default: break
            }
            b.row([.init("   "), .init(mark + " ", style), .init(stage.title.padding(toLength: 30, withPad: " ", startingAt: 0), stage == current ? .title : .normal),
                   .init(detail, .dim)], from: .wired("check.run"))
        }
        b.blank()
        switch state.check {
        case .passed(let pass):
            b.verdict(g.done, "Check passed: the pair loads, generates and lets go of its memory.", .good, from: .wired("check.run"))
            for line in state.cleanup { b.text(line, .dim, indent: 6, from: .wired("session.cleanup")) }
            _ = pass
            b.action("enter", "Next: start serving", from: .frame)
        case .failed(_, let reason):
            b.verdict(g.blocked, reason, .bad, from: .wired("check.run"))
            b.action("c", "Run the check again", from: .wired("check.run"))
        case .running:
            break
        case .idle:
            if let pass = state.record.checkPassed(configurationSHA256: saved.configurationSHA256) {
                var words = "Passed \(pass.at) on this setup: ready in \(String(format: "%.1f", pass.readySeconds)) s"
                if let first = pass.firstTokenMilliseconds { words += String(format: ", first token %.2f s", Double(first) / 1000) }
                if let rate = pass.tokensPerSecond { words += String(format: ", %.0f tok/s", rate) }
                b.verdict(g.done, words + ".", .good, from: .wired("check.run"))
                b.action("enter", "Next: start serving", from: .frame)
                b.action("c", "Run it again", from: .wired("check.run"))
            } else {
                b.action("c", "Run the check", from: .wired("check.run"))
            }
        }
    }

    // MARK: 6 Serve

    static func serve(_ state: ClusterSetupState, _ local: ClusterSetupReport, _ b: inout Builder) {
        let g = b.glyphs
        guard let saved = local.saved.setup else {
            b.verdict(g.waiting, "There is no saved setup to serve yet: step 4.", .warning, from: .wired("pair.saved"))
            return
        }
        if !saved.isLeader, saved.overLink == true {
            // Reached over the paired link: this Mac serves its own rank (`darkbloom cluster link-follower`).
            switch state.session {
            case .none, .ended:
                if case .ended(let description, let clean) = state.session {
                    b.verdict(clean ? g.done : g.blocked, "Following \(description).", clean ? .good : .bad, from: .wired("session.process"))
                    if !clean, !state.sessionOutput.isEmpty {
                        b.heading("Its last output")
                        for line in state.sessionOutput.suffix(6) { b.text(line, .dim, indent: 4, from: .wired("session.process")) }
                    }
                    b.blank()
                }
                b.fact("Model", "\(saved.publicModelID) \u{B7} this Mac holds rank \(saved.localRank)", from: .wired("pair.saved"))
                b.fact("Left wired", leftWired(local.memoryGuard), local.memoryGuard.decision == .refused ? .bad : .normal, from: .wired("session.cleanup"))
                b.action("s", "Start following: this Mac serves its rank to the leader over the paired link", enabled: local.memoryGuard.decision != .refused,
                    from: .wired("session.start"))
            case .launching:
                b.text("\(g.spin(state.now)) Starting `darkbloom cluster link-follower`\u{2026}", .accent, from: .wired("session.process"))
            case .running(let pid, _):
                b.text("\(g.spin(state.now)) Following (process \(pid)): the leader opens this Mac's rank over the paired link when it starts serving.",
                    .accent, from: .wired("session.process"))
                for line in state.sessionOutput.suffix(4) { b.text(line, .dim, indent: 4, from: .wired("session.process")) }
                b.action("x", "Stop following", from: .wired("session.stop"))
            case .stopping(let pid):
                b.text("\(g.spin(state.now)) Stopping process \(pid)\u{2026}", .accent, from: .wired("session.process"))
            }
            return
        }
        guard saved.isLeader else {
            b.verdict(g.done, "This Mac follows: the leader starts and stops serving and reaches this Mac itself.", .good, from: .wired("pair.saved"))
            b.fact("Device", local.journal == .ownershipUnproven ? "in use by a session (journal not empty)" : "idle (journal empty)", from: .wired("journal.state"))
            b.fact("Left wired", leftWired(local.memoryGuard), from: .wired("session.cleanup"))
            return
        }
        switch state.session {
        case .none, .ended:
            if case .ended(let description, let clean) = state.session {
                b.verdict(clean ? g.done : g.blocked, "Serving \(description).", clean ? .good : .bad, from: .wired("session.process"))
                if !state.cleanup.isEmpty {
                    b.heading("Clean up")
                    for line in state.cleanup { b.text(line, indent: 3, from: .wired("session.cleanup")) }
                }
                if !clean, !state.sessionOutput.isEmpty {
                    b.heading("Its last output")
                    for line in state.sessionOutput.suffix(6) { b.text(line, .dim, indent: 4, from: .wired("session.process")) }
                }
                b.blank()
            }
            b.fact("Model", "\(saved.publicModelID) \u{B7} \(saved.stages.map { "\($0.memberID) \($0.firstLayer)-\($0.endLayer - 1)" }.joined(separator: " \u{B7} "))", from: .wired("pair.saved"))
            b.fact("Left wired", leftWired(local.memoryGuard), local.memoryGuard.decision == .refused ? .bad : .normal, from: .wired("session.cleanup"))
            if let peer = state.peerReport {
                b.fact("Other Mac", leftWired(peer.memoryGuard, whose: "its"), peer.memoryGuard.decision == .refused ? .bad : .normal, from: .wired("peer.report"))
            }
            if state.record.checkPassed(configurationSHA256: saved.configurationSHA256) == nil {
                b.text("The check (step 5) has not passed on this setup; serving can still start.", .warning, from: .wired("check.run"))
            }
            b.action("s", "Start serving: `darkbloom start --local --distributed`", enabled: local.memoryGuard.decision != .refused, from: .wired("session.start"))
        case .launching:
            b.text("\(g.spin(state.now)) Starting `darkbloom start --local --distributed`\u{2026}", .accent, from: .wired("session.process"))
        case .running(let pid, let since):
            live(state, saved, pid: pid, since: since, &b)
        case .stopping(let pid):
            live(state, saved, pid: pid, since: nil, &b)
        }
    }

    static func live(_ state: ClusterSetupState, _ saved: ClusterSetupSetupSummary, pid: Int32, since: UInt64?, _ b: inout Builder) {
        let g = b.glyphs
        let stopping: Bool = { if case .stopping = state.session { return true }; return false }()
        if let live = state.live, live.observed {
            let head = live.ready ? "\(g.current) Serving \(saved.publicModelID)" : "\(g.spin(state.now)) Loading \(saved.publicModelID): \(live.readyRanks) of \(max(live.members.count, 2)) ranks ready"
            var parts = [head]
            if let port = live.port { parts.append("127.0.0.1:\(port)") }
            if let since { parts.append("up \(seconds(state.now, since))") }
            b.text(parts.joined(separator: " \u{B7} "), live.ready ? .good : .accent, indent: 1, from: .wired("session.status"))
            var limits = [String]()
            if let served = live.requestsServed { limits.append("\(served) requests served") }
            if let warm = live.keepWarmExchanges, warm > 0 { limits.append("\(warm) keep-warm exchanges") }
            if live.activeRequest { limits.append("a request is running") }
            if !limits.isEmpty { b.text(limits.joined(separator: " \u{B7} "), .dim, indent: 3, from: .wired("session.status")) }
            for member in live.members {
                let local = member.memberID == saved.memberID
                var memory = ""
                if local, let wired = live.localWiredBytes, let total = live.localPhysicalBytes {
                    memory = ClusterSetupScreen.bar(wired, of: total, width: 12, glyphs: g) + " \(ClusterSetupScreen.gib(wired)) wired of \(ClusterSetupScreen.gib(total))"
                } else if !local, let peer = state.peerReport, let wired = peer.memoryGuard.wiredBytes {
                    memory = ClusterSetupScreen.bar(wired, of: peer.mac.physicalMemoryBytes, width: 12, glyphs: g) + " \(ClusterSetupScreen.gib(wired)) wired of \(ClusterSetupScreen.gib(peer.mac.physicalMemoryBytes))"
                }
                b.row([.init("   Rank \(member.rank)  "), .init((member.memberID + (local ? " (this Mac)" : "")).padding(toLength: 18, withPad: " ", startingAt: 0)),
                       .init((member.ready ? "ready" : "loading").padding(toLength: 9, withPad: " ", startingAt: 0), member.ready ? .good : .accent),
                       .init(memory, .dim)], from: .wired("session.status"))
            }
            if let link = live.linkState {
                let tb = state.local?.link.clusterConnection.map { " \u{B7} \(connectionWords($0))" } ?? ""
                b.text("Link \(link == "ready" ? "ready" : "NOT ready (\(link))")\(tb)", link == "ready" ? .normal : .bad, indent: 3, from: .wired("link.port"))
            }
            if live.quarantined { b.verdict(g.blocked, "Quarantined: an owner has not released its device.", .bad, from: .wired("session.status")) }
        } else if let live = state.live, let detail = live.detail, let since, state.now >= since + statusGraceNanoseconds {
            // A leader still without status after the grace: why its status cannot be read.
            b.text("\(g.spin(state.now)) No status from the leader after \(seconds(state.now, since)): \(detail)", .warning, indent: 1, from: .wired("session.status"))
        } else {
            // While a session starts its status is not there yet; that is not shown as an error.
            let elapsed = since.map { " \(seconds(state.now, $0))" } ?? ""
            b.text("\(g.spin(state.now)) Process \(pid) started; both Macs are loading the model\u{2026}\(elapsed)", .accent, indent: 1, from: .wired("session.process"))
        }
        b.blank()
        switch state.prompt {
        case .closed:
            if !stopping, state.live?.ready == true {
                b.action("t", "Send a test prompt", from: .wired("host.request"))
            }
        case .editing(let text):
            b.row([.init("   > ", .accent), .init(text, .title), .init("_", .accent)], from: .wired("host.request"))
            b.text("enter sends it to the local API with a limit of \(ClusterSetupState.promptTokens) tokens; esc closes.", .dim, from: .frame)
        case .sending(let text, let reply), .answered(let text, let reply, _):
            b.row([.init("   > ", .accent), .init(text, .dim)], from: .wired("host.request"))
            b.text(reply.isEmpty ? "\(g.spin(state.now)) \u{2026}" : reply.replacingOccurrences(of: "\n", with: " "), indent: 5, from: .wired("host.request"))
            if case .answered(_, _, let result) = state.prompt {
                b.text(ClusterSetupState.describe(result), .good, indent: 5, from: .wired("host.request"))
                b.action("t", "Another prompt", from: .wired("host.request"))
            }
        case .failed(let text, let reason):
            b.row([.init("   > ", .accent), .init(text, .dim)], from: .wired("host.request"))
            b.verdict(g.blocked, reason, .bad, from: .wired("host.request"))
        }
        if stopping {
            b.text("Stopping: both Macs release their workers; the screen reads them again when it ends.", .warning, indent: 3, from: .wired("session.stop"))
        } else {
            b.action("x", "Stop serving", from: .wired("session.stop"))
        }
    }

    // MARK: - Keys

    /// The label of Enter on this step now.
    static func primaryLabel(_ state: ClusterSetupState) -> String? {
        guard state.snapshot != nil else { return nil }
        let status = state.status(of: state.step)
        switch state.step {
        case .thisMac: return status == .blocked ? "read again" : "next"
        case .cable: return status == .todo ? "fix link" : status == .done ? "next" : "read again"
        case .pair:
            if state.pairingConfirmed { return "next" }
            if state.pair?.canReachPeer == true, state.peerReport == nil { return "reach" }
            return state.pairingCode != nil ? "codes match" : "read again"
        case .model:
            if status == .done { return "next" }
            if state.local?.inbox != nil { return "approve" }
            if state.savedSetup?.isLeader == true { return "look again" }
            return state.mayPlan ? "use plan" : nil
        case .check: return status == .done ? "next" : (state.savedSetup?.isLeader == true ? "run check" : "next")
        case .serve:
            if case .running = state.session { return "test prompt" }
            return state.session.isActive || state.savedSetup?.isLeader != true ? nil : "start"
        }
    }

    static func stepKeys(_ state: ClusterSetupState, glyphs: ClusterSetupGlyphs = .unicode) -> [(String, String)] {
        switch state.step {
        case .cable: return [("f", "fix link")]
        case .pair: return state.pair?.canReachPeer == true ? [("p", "reach again")] : []
        case .model:
            var keys = [(String, String)]()
            if case .ready = state.plans { keys.append((glyphs.upDown, "choose")) }
            if state.local?.inbox != nil { keys.append(("a", "approve")) }
            if state.savedSetup?.isLeader == true { keys.append(("p", "look again")) }
            return keys
        case .check: return state.savedSetup?.isLeader == true ? [("c", "check")] : []
        case .serve:
            if case .running = state.session { return [("t", "prompt"), ("x", "stop")] }
            if case .stopping = state.session { return [] }
            return state.savedSetup?.isLeader == true ? [("s", "start")] : []
        case .thisMac: return []
        }
    }

    // MARK: - Help

    static func help(_ state: ClusterSetupState, width: Int, glyphs: ClusterSetupGlyphs) -> [Line] {
        var b = Builder(width: width, glyphs: glyphs, interactive: true)
        b.heading("About this step")
        for line in stepHelp(state.step) { b.text(line, from: .frame) }
        b.blank()
        b.heading("Keys")
        for (key, text) in [("enter", "the step's one action, or the next step once it is done"), ("\u{2190} \u{2192}  or 1-6", "move between steps"),
                            ("r", "read everything again"), ("?", "this help"), ("q, Ctrl-C", "close; serving started here is stopped first"),
                            ("y", "answers yes to a question, once it has been on screen half a second; any other key answers no")] {
            b.fact(key, text, from: .frame)
        }
        b.blank()
        b.heading("Not available in this build")
        for item in ClusterSetupWizardWiring.unavailable { b.text("\(item.title): \(item.reason)", .dim, from: .frame) }
        if !state.activity.isEmpty {
            b.blank()
            b.heading("Recent activity")
            for entry in state.activity.suffix(8) {
                b.text("\(entry.time) \(entry.title): \(entry.lines.first ?? "")", entry.failed ? .bad : .dim, from: .frame)
            }
        }
        return b.lines
    }

    static func stepHelp(_ step: ClusterSetupStep) -> [String] {
        switch step {
        case .thisMac:
            return ["What this Mac brings: its chip, the memory a model can use (the GPU's working set and what the load gate admits now), disk, macOS and whether RDMA over Thunderbolt is on.",
                    "RDMA can only be turned on from macOS Recovery (`rdma_ctl enable`); Darkbloom never changes it. Memory left wired by a crashed run is reported here: only a restart frees it."]
        case .cable:
            return ["The Thunderbolt port that carries the cluster: whether it is ready for RDMA, the link speed (Thunderbolt 5 links run at 80 Gb/s or more; 40 Gb/s is Thunderbolt 4 or USB4 and cannot carry RDMA), and whether the port belongs to the cluster alone.",
                    "Fix link shows the exact commands first. Only after y does macOS ask once for an administrator; Darkbloom never uses sudo and never changes Internet Sharing."]
        case .pair:
            return ["The two Macs pair over the Thunderbolt cable with their Secure Enclave keys: no SSH, no address and no network setting.",
                    "The pairing code is the same six digits on both screens when the Mac that answered is the Mac in front of you. Confirm only when you have read both."]
        case .model:
            return ["Each model folder found on this Mac, whether the other Mac has the same artifact, and the planner's choice from both Macs' memory now: which Mac holds which layers, the mode, the predicted speed against each Mac alone, and what each rank needs against what its Mac has free.",
                    "Using a plan saves this Mac's setup and sends the other Mac its own; the other Mac approves it on its own screen. Nothing starts."]
        case .check:
            return ["A short end-to-end proof across the cable: both links, a start, both ranks loaded (\u{201C}0 of 2 ranks ready\u{201D} counts up), a few tokens through the local API, a stop, and the memory released on both Macs (journal empty, wired memory back under the idle baseline)."]
        case .serve:
            return ["Starts `darkbloom start --local --distributed`, shows both ranks, memory on each Mac, the link and the last request, and lets you send a test prompt. Stop asks the session to end the way Ctrl-C would and then reads both Macs again to show what was released."]
        }
    }

    // MARK: - Plain output

    /// The six steps as text for a pipe or a log: no keys, no scrolling.
    static func plain(_ snapshot: ClusterSetupSnapshot, dryRun: Bool = false) -> [String] {
        var state = ClusterSetupState(size: .init(columns: 100, rows: 1000), options: .init(dryRun: dryRun))
        state.snapshot = snapshot
        var out = [String]()
        for step in ClusterSetupStep.allCases {
            state.step = step
            let status: String
            switch state.status(of: step) {
            case .done: status = "done"
            case .todo: status = "to do"
            case .blocked: status = "blocked"
            case .waiting: status = "waiting"
            }
            out.append("Step \(step.number): \(step.title) [\(status)]")
            out += body(state, width: 100, glyphs: .ascii, interactive: false).map(\.text)
            out.append("")
        }
        return out
    }
}

extension ClusterSetupSnapshot {
    /// The six steps as text, for `darkbloom cluster --plain`.
    public func plainLines(dryRun: Bool = false) -> [String] { ClusterSetupContent.plain(self, dryRun: dryRun) }
}
