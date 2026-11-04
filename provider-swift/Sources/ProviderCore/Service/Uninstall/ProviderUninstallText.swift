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
                     "     The app, settings, pairing, logs and all models · frees \(formatBytes(plan.frees(.everything)))",
                     "  2) Keep models",
                     plan.models.isEmpty ? "     Removes everything else (no models are downloaded)"
                        : "     Removes everything else; a reinstall reuses the \(formatBytes(plan.modelBytes)) of models"]
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
        action("\(clusterStep), as `\(plan.cli) cluster stop`: "
            + (plan.clusterService.isEmpty ? "no cluster service on this Mac" : plan.clusterService.joined(separator: ", ")))
        for service in plan.services {
            action("Remove the \(service.name): \(service.path ?? "not installed")")
        }
        action("\(tokenStep), as `\(plan.cli) logout` does (best effort)")
        for peer in plan.pairing?.peers ?? [] { action("Forget the pairing with \(peer.name), as `\(plan.cli) cluster pair --forget`") }
        action("\(cableStep), as `\(plan.cli) cluster link --remove` (macOS asks for an administrator's password)")
        for item in plan.removed(mode) { action("Delete \(row(item))") }
        lines.append("  Frees \(formatBytes(plan.frees(mode))) (APFS clones counted once).")
        if mode == .keepModels, !plan.models.isEmpty { lines.append("  " + keptModelsLine(plan)) }
        lines += plan.refused.map { "  Not deleted: \($0.label) (\($0.path)): \($0.reason ?? "")" }
        lines += neverTouched(plan).map { "  \($0)" }
        return lines
    }

    /// The summary after a run: each step with its status, what was kept and where, then the way back and the other Mac.
    public static func summary(_ report: Report, plan: Plan) -> [String] {
        let headline = report.failed ? "Darkbloom is not fully removed from this Mac (see the failed step)."
            : report.incomplete ? "Darkbloom is not fully removed from this Mac: some of its folders were not removed (see below)."
            : report.mode == .keepModels ? "Darkbloom is removed from this Mac; its models are kept."
            : "Darkbloom is removed from this Mac."
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

    /// What no option deletes: folders the person chose or outside Darkbloom's, Keychain keys, and what has its own
    /// uninstall. A chosen models folder inside Darkbloom's own is named as kept.
    static func neverTouched(_ plan: Plan) -> [String] {
        plan.kept.map { "\($0.keptInDarkbloomFolder ? "Kept" : "Never touched"): \($0.label) (\(formatBytes($0.bytes)), \($0.path)): "
            + ($0.reason ?? "") } + [keychainLine] + plan.elsewhere
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
        item.keeping.isEmpty ? item.label : item.label + ", except the models you chose"
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
            actions.append(.init(action: cableStep, path: nil, bytes: nil))
            actions += plan.removed(mode).map { .init(action: "Delete \(deletedLabel($0))", path: $0.path, bytes: $0.bytes) }
            let keptModels = mode == .keepModels ? plan.models : []
            return .init(mode: mode, actions: actions, frees: plan.frees(mode), kept: keptModels + plan.kept, refused: plan.refused)
        }
        return .init(modes: modePlans, neverTouched: [keychainLine] + plan.elsewhere,
                     otherMac: plan.pairing.map { otherMacLine($0, cli: plan.cli) })
    }
}
