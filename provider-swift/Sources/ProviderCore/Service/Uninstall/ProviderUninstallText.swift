import Foundation

// MARK: - What the person reads

extension ProviderUninstall {
    public static let keychainLine = "Never touched: Keychain keys (Secure Enclave and App Attest); a new install replaces them."
    public static let choicePrompt = "  Choose 1 or 2 (Esc cancels): "

    /// Asked once after 1 on the screen, which deletes the models too.
    public static func everythingQuestion(_ plan: Plan) -> String {
        plan.models.isEmpty ? "  Remove everything? This can't be undone. [y/N]: "
            : "  Remove everything, including \(formatBytes(plan.modelBytes)) of models? This can't be undone. [y/N]: "
    }

    /// y or yes; anything else, nothing included, is no.
    public static func confirmed(_ answer: String?) -> Bool {
        ["y", "yes"].contains(answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    /// Run as root, it would read root's home, find nothing of the person's Darkbloom and still undo the Mac's cable setup.
    public static func rootRefusal(cli: String = BuildEnvironment.current.cliName) -> String {
        "Run `\(cli) uninstall` as yourself, not with sudo: it removes your own Darkbloom, and asks for your password when a "
            + "step needs it."
    }

    public static func usage(cli: String = BuildEnvironment.current.cliName) -> String {
        "Usage: \(cli) uninstall --everything|--keep-models [--yes] [--dry-run [--json]] (no terminal to ask which)"
    }

    /// The interactive screen above `choicePrompt`. Lines below the two choices appear only when this Mac has
    /// folders no option deletes, or Darkbloom parts with their own uninstall.
    public static func screen(_ plan: Plan) -> [String] {
        var lines = ["Uninstall Darkbloom from this Mac", "",
                     "  1) Remove everything",
                     "     \(everythingRemoves(plan)) · frees \(formatBytes(plan.frees(.everything)))",
                     "  2) Keep models",
                     !plan.models.isEmpty ? "     Removes everything else; a reinstall reuses the \(formatBytes(plan.modelBytes)) of models"
                        : keepsModels(plan) ? "     Removes everything else; the models stay either way (below)"
                        : "     Removes everything else (no models are downloaded)"]
        let notes = neverTouched(plan).filter { $0 != keychainLine }
            + plan.refused.map { "Not deleted: \($0.label) (\($0.path)): \($0.reason ?? "")" }
        if !notes.isEmpty { lines += [""] + notes.map { "  \($0)" } }
        lines.append("")
        return lines
    }

    /// `--dry-run`: every action and path, with sizes, for `mode`.
    public static func dryRun(_ plan: Plan, mode: Mode) -> [String] {
        var lines = ["\(plan.cli) uninstall --\(mode.rawValue) would, changing nothing now:"]
        var number = 0
        func action(_ text: String) { number += 1; lines.append("  \(number). \(text)") }
        action("\(stopServingStep): drain accepted requests, as `\(plan.cli) stop`")
        let said = [plan.clusterService.isEmpty ? nil : plan.clusterService.joined(separator: ", "),
                    plan.runningClusterService.map { clusterStop($0, cli: plan.cli) }].compactMap { $0 }
        action("\(clusterStep), as `\(plan.cli) cluster stop --service`: "
            + (!said.isEmpty ? said.joined(separator: "; ")
                : plan.clusterServiceRunning
                    ? "a cluster service is running on this Mac: this stops a `\(plan.cli) cluster service`, and nothing is deleted while any other runs"
                : "no cluster service on this Mac"))
        for service in plan.services {
            action("Remove the \(service.name): \(service.path ?? "not installed")")
        }
        action("\(tokenStep), as `\(plan.cli) logout` does (best effort)")
        for peer in plan.pairing?.peers ?? [] { action("Forget the pairing with \(peer.name), as `\(plan.cli) cluster pair --forget`") }
        if plan.cableKeptFor == nil {
            action("\(cableStep), as `\(plan.cli) cluster link --remove` (macOS asks for an administrator's password)")
        }
        for item in plan.removed(mode) { action("Delete \(row(item))") }
        lines.append("  Frees \(formatBytes(plan.frees(mode))) (APFS clones counted once).")
        if mode == .keepModels, !plan.models.isEmpty { lines.append("  " + keptModelsLine(plan)) }
        lines += plan.refused.map { "  Not deleted: \($0.label) (\($0.path)): \($0.reason ?? "")" }
        lines += neverTouched(plan).map { "  \($0)" }
        return lines
    }

    /// The summary after a run: each step with its status, what was kept and where, then the way back and the other Mac.
    public static func summary(_ report: Report, plan: Plan) -> [String] {
        var name = "Darkbloom"
        if plan.cableKeptFor != nil, let this = BuildEnvironment.allCases.first(where: { $0.cliName == plan.cli }) {
            // Beside another install, "Darkbloom" alone would also mean the one that stays.
            name = installName(this).prefix(1).uppercased() + installName(this).dropFirst()
        }
        let headline = report.failed ? "\(name) is not fully removed from this Mac (see the failed step)."
            : report.incomplete ? "\(name) is not fully removed from this Mac: " + incompleteReason(plan)
            : report.mode == .keepModels ? "\(name) is removed from this Mac; its models are kept."
            : "\(name) is removed from this Mac."
        var lines = [headline]
        lines += report.steps.map { step in
            let status = step.status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            return "  \(status) \(step.name)" + (step.detail.map { ": \($0)" } ?? "")
        }
        if let before = report.availableBefore, let after = report.availableAfter,
           report.steps.contains(where: { $0.name.hasPrefix("Delete ") && $0.status == .done }) {
            lines.append("Space freed: \(formatBytes(max(0, after - before))) (this disk had \(formatBytes(before)) free, now \(formatBytes(after))).")
        }
        if report.mode == .keepModels, !plan.models.isEmpty { lines.append(keptModelsLine(plan)) }
        lines += neverTouched(plan)
        if report.mode == .keepModels {
            lines.append("To come back: run `\(plan.installCommand)`, then `\(plan.cli) start` or `\(plan.cli) cluster`; "
                + "the models are found automatically.")
            if plan.kept.contains(where: { $0.label == chosenModelsLabel }) {
                lines.append("Models in the folder you chose are not found automatically: after installing, run "
                    + "`\(plan.cli) models location <folder>`.")
            }
        }
        if let pairing = plan.pairing { lines.append(otherMacLine(pairing, cli: plan.cli)) }
        return lines
    }

    /// What `cluster stop --service` does to the cluster service running here: it stops one whose command is
    /// `<cli> cluster service`, wherever that runs from; anything else stays, and nothing is deleted while it runs.
    static func clusterStop(_ running: RunningClusterService, cli: String) -> String {
        switch running.owner {
        case .thisInstall: return "\(running.described); this stops it"
        case .unknown where running.isThisCLI:
            return "a `\(cli) cluster service` from outside this install's app is running (pid \(running.pid)); this stops it too"
        default:
            let what = running.note ?? "a cluster service from outside this install's app, under another name, is running (pid \(running.pid))"
            return "\(what); this does not stop it, and nothing is deleted while it runs"
        }
    }

    /// What option 1 removes on this Mac: no "all models" while some stay.
    static func everythingRemoves(_ plan: Plan) -> String {
        let models = plan.models.isEmpty ? nil : keepsModels(plan) ? "the models not kept below" : "all models"
        let parts = ["The app", "settings", "pairing", "logs"] + (models.map { [$0] } ?? [])
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// Whether models stay whichever option: chosen, shared with another install, or behind a link.
    static func keepsModels(_ plan: Plan) -> Bool {
        plan.kept.contains { $0.kind == .model || $0.label == chosenModelsLabel || $0.label == chosenStoreLabel || $0.label == linkedModelsLabel }
    }

    /// Why the run left something of Darkbloom's: its app folder is (in) the models folder the person chose, or a folder
    /// was refused.
    static func incompleteReason(_ plan: Plan) -> String {
        let reasons = plan.refused.filter { $0.kind == .command }.compactMap(\.reason)
        return reasons.contains { $0.hasPrefix(chosenFolderIsItReason) } ? "its app folder is your models folder, so it was kept (see below)."
            : reasons.contains { $0.hasPrefix(chosenFolderHoldsItReason) } ? "its app folder is inside your models folder, so it was kept (see below)."
            : "some of its folders were not removed (see below)."
    }

    /// The models `--keep-models` keeps, with their size and folders.
    static func keptModelsLine(_ plan: Plan) -> String {
        let count = plan.models.filter { URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("models--") }.count
        let store = plan.models.contains { $0.label == clusterStoreLabel }
        let folders = Set(plan.models.map {
            $0.label == clusterStoreLabel ? $0.path : URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
        }).sorted()
        return "Kept: \(count) model\(count == 1 ? "" : "s")\(store ? " and the cluster model store" : ""), "
            + "\(formatBytes(plan.modelBytes)), in \(folders.joined(separator: " and "))."
    }

    /// What no option deletes: folders the person chose or outside Darkbloom's, the cable port setup another install
    /// on this Mac may use, Keychain keys, and what has its own uninstall. A chosen models folder inside Darkbloom's
    /// own is named as kept.
    static func neverTouched(_ plan: Plan) -> [String] {
        plan.kept.map { "\($0.keptInDarkbloomFolder ? "Kept" : "Never touched"): \($0.label) (\(formatBytes($0.bytes)), \($0.path)): "
            + ($0.reason ?? "") } + (plan.cableKeptFor.map { [cableKeptLine($0)] } ?? []) + [keychainLine] + plan.elsewhere
    }

    /// Beside another install: the cable port setup stays, and which uninstall undoes it.
    static func cableKeptLine(_ other: BuildEnvironment) -> String {
        "Kept: this Mac's cable port setup: \(installName(other)) on this Mac may use the same cable. Run `\(other.cliName) uninstall` "
            + "there to undo it"
    }

    /// The last line on a paired Mac, about the other one.
    static func otherMacLine(_ pairing: ProviderUninstallPairing, cli: String) -> String {
        let name = pairing.otherMacName.map { "The other Mac (\($0))" } ?? "The other Mac"
        let relation: String
        switch pairing.role {
        case .leader: relation = "followed this one"
        case .member: relation = "led this pair"
        case nil: relation = "is paired with this one"
        }
        return "\(name) \(relation): run `\(cli) uninstall` there too, or `\(cli) cluster` on it to pair it with another Mac."
    }

    static func row(_ item: ProviderUninstallItem) -> String {
        let label = deletedLabel(item)
        return item.bytes > 0 ? "\(label)  \(formatBytes(item.bytes))  \(item.path)" : "\(label)  \(item.path)"
    }

    /// What deleting `item` takes: all of it, or all but the models folder the person chose inside it.
    static func deletedLabel(_ item: ProviderUninstallItem) -> String {
        item.keeping.isEmpty ? item.label : item.label + ", except " + item.keepingWhat
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Choosing a mode

extension ProviderUninstall {
    public enum Invocation: Equatable, Sendable {
        /// Ask on the screen (a terminal, no mode given).
        case ask
        /// Run `mode`; `confirm` asks once in the terminal first.
        case run(Mode, confirm: Bool)
        case dryRun([Mode])
        /// Refused before anything runs, with the line to print.
        case refuse(String)
    }

    /// What one read of keys on the screen means: a choice, cancel, or nothing (keep waiting).
    public enum Key: Equatable, Sendable {
        case choose(Mode)
        case cancel
    }

    /// `1` or `2` choose; Esc alone, `q`, Ctrl-C, Ctrl-D or the end of input cancel; anything else (an arrow key's
    /// escape sequence too) is ignored.
    public static func key(_ bytes: [UInt8]) -> Key? {
        switch bytes {
        case [UInt8(ascii: "1")]: return .choose(.everything)
        case [UInt8(ascii: "2")]: return .choose(.keepModels)
        case [], [0x1B], [UInt8(ascii: "q")], [0x03], [0x04]: return .cancel
        default: return nil
        }
    }

    public static func invocation(everything: Bool, keepModels: Bool, yes: Bool, dryRun: Bool, interactive: Bool,
                                  userID: uid_t = geteuid(), cli: String = BuildEnvironment.current.cliName) -> Invocation {
        guard userID != 0 else { return .refuse(rootRefusal(cli: cli)) }
        let mode: Mode? = everything ? .everything : keepModels ? .keepModels : nil
        if dryRun { return .dryRun(mode.map { [$0] } ?? Mode.allCases) }
        guard let mode else { return interactive ? .ask : .refuse(usage(cli: cli)) }
        if yes { return .run(mode, confirm: false) }
        return interactive ? .run(mode, confirm: true) : .refuse(usage(cli: cli))
    }
}

// MARK: - Dry run as JSON

extension ProviderUninstall {
    public struct DryRunDocument: Encodable {
        public struct Action: Encodable { let action: String; let path: String?; let bytes: Int64? }
        public struct ModePlan: Encodable {
            let mode: Mode
            let actions: [Action]
            /// Bytes the deletions free, APFS clones counted once.
            let frees: Int64
            let kept: [ProviderUninstallItem]
            let refused: [ProviderUninstallItem]
        }
        public let schema = "darkbloom_uninstall_plan_v1"
        public let modes: [ModePlan]
        /// What no option removes, each with how to remove it.
        public let neverTouched: [String]
        public let otherMac: String?
    }

    public static func dryRunDocument(_ plan: Plan, modes: [Mode]) -> DryRunDocument {
        let modePlans = modes.map { mode -> DryRunDocument.ModePlan in
            var actions = [DryRunDocument.Action(action: stopServingStep, path: nil, bytes: nil)]
            let clusterAgents: [String?] = plan.clusterService.isEmpty ? [nil] : plan.clusterService
            actions += clusterAgents.map { .init(action: clusterStep, path: $0, bytes: nil) }
            actions += plan.services.map { .init(action: "Remove the \($0.name)", path: $0.path, bytes: nil) }
            actions.append(.init(action: tokenStep, path: nil, bytes: nil))
            actions += (plan.pairing?.peers ?? []).map { .init(action: "Forget the pairing with \($0.name)", path: nil, bytes: nil) }
            if plan.cableKeptFor == nil { actions.append(.init(action: cableStep, path: nil, bytes: nil)) }
            actions += plan.removed(mode).map { .init(action: "Delete \(deletedLabel($0))", path: $0.path, bytes: $0.bytes) }
            let keptModels = mode == .keepModels ? plan.models : []
            return .init(mode: mode, actions: actions, frees: plan.frees(mode), kept: keptModels + plan.kept, refused: plan.refused)
        }
        return .init(modes: modePlans, neverTouched: (plan.cableKeptFor.map { [cableKeptLine($0)] } ?? []) + [keychainLine] + plan.elsewhere,
                     otherMac: plan.pairing.map { otherMacLine($0, cli: plan.cli) })
    }
}
