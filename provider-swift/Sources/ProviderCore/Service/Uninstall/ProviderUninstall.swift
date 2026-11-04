import Foundation

/// `darkbloom uninstall`: takes Darkbloom off this Mac. Both ways stop serving, remove every background service,
/// revoke the account token (best effort), unpair, undo the cable port setup and delete Darkbloom's folders
/// (`ProviderUninstallPaths`), the app last. `keepModels` keeps the model folders Darkbloom downloaded and the
/// cluster model store, so a reinstall finds them. Nothing in the Keychain is touched. Each step is idempotent; a
/// failed one is reported and the safe ones after it still run.
public enum ProviderUninstall {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case everything
        case keepModels = "keep-models"
    }

    /// How a step ended when it did not throw.
    public enum Outcome: Equatable, Sendable {
        case done(String? = nil)
        case skipped(String)
    }

    public struct Step: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case done, skipped, failed }
        public let name: String
        public let status: Status
        public let detail: String?
    }

    /// Everything a run touches outside this file, so that checks can run it on a fake home with no launchd.
    public struct Operations {
        /// Drains and stops the provider, as `darkbloom stop` does.
        public var stopServing: () async throws -> Outcome
        /// Stops this Mac's part of a pair and removes the cluster service, as `darkbloom cluster stop` does.
        public var stopClusterPart: () async throws -> Outcome
        /// The provider, watchdog and desktop API launch agents, by name, as `darkbloom stop --uninstall` removes them.
        public var removeServices: [(name: String, remove: () throws -> Outcome)]
        /// Called once the services are handled, before any account, pairing or file changes (releases the drain's lease).
        public var servicesHandled: () -> Void
        /// Revokes the saved account token as `darkbloom logout` does. Best effort: it reports, it never fails.
        public var revokeToken: () async -> Outcome
        /// `darkbloom cluster pair --forget <pin>`.
        public var forget: (_ peerPin: String) throws -> Void
        /// `darkbloom cluster link --remove`.
        public var removeCableSetup: () throws -> Outcome
        public var delete: (URL) throws -> Void
        /// Free bytes on the home volume, to report the space freed.
        public var availableBytes: () -> Int64?

        public init(stopServing: @escaping () async throws -> Outcome, stopClusterPart: @escaping () async throws -> Outcome,
                    removeServices: [(name: String, remove: () throws -> Outcome)], servicesHandled: @escaping () -> Void = {},
                    revokeToken: @escaping () async -> Outcome,
                    forget: @escaping (String) throws -> Void, removeCableSetup: @escaping () throws -> Outcome,
                    delete: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                    availableBytes: @escaping () -> Int64? = { nil }) {
            self.stopServing = stopServing; self.stopClusterPart = stopClusterPart; self.removeServices = removeServices
            self.servicesHandled = servicesHandled; self.revokeToken = revokeToken; self.forget = forget
            self.removeCableSetup = removeCableSetup; self.delete = delete; self.availableBytes = availableBytes
        }
    }

    public struct Report: Sendable, Equatable {
        public let mode: Mode
        public let steps: [Step]
        public let availableBefore: Int64?
        public let availableAfter: Int64?
        public var failed: Bool { steps.contains { $0.status == .failed } }
    }

    static let stopServingStep = "Stop serving on this Mac"
    static let clusterStep = "Stop this Mac's cluster part and remove its service"
    static let tokenStep = "Revoke this Mac's account token"
    static let cableStep = "Undo the cable port setup"
    static let stillServingReason = "serving did not stop (see the failed step above)"
    static let servicesRunningReason = "a Darkbloom service may still be running (see the failed step above)"
    static let cableRetryReason =
        "kept, so the uninstall can run again and undo the cable port setup (it holds the app and the cable records)"

    /// Runs `mode`. `items` is `inventory(_:)`, read before anything changed; `announce` prints each step as it starts.
    public static func run(_ mode: Mode, items: [ProviderUninstallItem], pairing: ProviderUninstallPairing?,
                           operations: Operations, announce: (String) -> Void = { _ in }) async -> Report {
        var steps: [Step] = []
        func step(_ name: String, _ body: () async throws -> Outcome) async -> Bool {
            announce(name)
            do {
                switch try await body() {
                case .done(let detail): steps.append(.init(name: name, status: .done, detail: detail))
                case .skipped(let reason): steps.append(.init(name: name, status: .skipped, detail: reason))
                }
                return true
            } catch {
                steps.append(.init(name: name, status: .failed, detail: "\(error)"))
                return false
            }
        }
        let serving = await step(stopServingStep, operations.stopServing)
        var servicesStopped = await step(clusterStep, operations.stopClusterPart) && serving
        for service in operations.removeServices {
            // As `stop --uninstall`: a provider that did not drain keeps its agents, so nothing interrupts it.
            guard serving else {
                steps.append(.init(name: service.name, status: .skipped, detail: stillServingReason))
                continue
            }
            servicesStopped = await step(service.name, service.remove) && servicesStopped
        }
        operations.servicesHandled()
        // As `darkbloom logout`: only once the provider holding the token has stopped.
        if serving {
            _ = await step(tokenStep) { await operations.revokeToken() }
        } else {
            steps.append(.init(name: tokenStep, status: .skipped, detail: stillServingReason))
        }
        if let pairing {
            for peer in pairing.peers {
                _ = await step("Forget the pairing with \(peer.name)") { try operations.forget(peer.pin); return .done() }
            }
        } else {
            steps.append(.init(name: "Forget this Mac's pairing", status: .skipped, detail: "this Mac is not paired"))
        }
        // After the pairing, which tells the other Mac over the cable; this takes the cable's address away.
        let cableUndone = await step(cableStep, operations.removeCableSetup)
        let before = operations.availableBytes()
        for item in items where item.verdict != .keep && !(mode == .keepModels && item.kind == .model) {
            let name = "Delete \(item.label)"
            guard item.verdict == .remove else {
                steps.append(.init(name: name, status: .skipped, detail: "refused: \(item.reason ?? "outside Darkbloom's folders")"))
                continue
            }
            guard servicesStopped else {
                steps.append(.init(name: name, status: .skipped, detail: servicesRunningReason))
                continue
            }
            guard cableUndone || item.kind != .command else {
                steps.append(.init(name: name, status: .skipped, detail: cableRetryReason))
                continue
            }
            _ = await step(name) {
                // The install folder holds the app this command runs from; it is deleted last. macOS keeps a
                // running executable's image after its file is unlinked, and nothing after this loads from it.
                guard FileManager.default.fileExists(atPath: item.path) || isLink(item.path) else { return .skipped("already gone") }
                try operations.delete(URL(fileURLWithPath: item.path))
                return .done(item.bytes > 0 ? formatBytes(item.bytes) : nil)
            }
        }
        return Report(mode: mode, steps: steps, availableBefore: before, availableAfter: operations.availableBytes())
    }

    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// One launch agent: skipped when neither its file nor a loaded job exists, else removed by its own `uninstall`.
    public static func removeAgent(plist: URL, loaded: @autoclosure () -> Bool, uninstall: () throws -> Void) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: plist.path) || loaded() else { return .skipped("not installed") }
        try uninstall()
        return .done()
    }

    /// A step that ended without the wanted result, in a sentence.
    public struct StepFailure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}

// MARK: - What the person reads

extension ProviderUninstall {
    /// What `darkbloom uninstall` (or `--dry-run`) runs on this Mac, in order.
    public struct Plan: Sendable, Equatable {
        public struct Service: Sendable, Equatable {
            public let name: String
            /// The launch agent file, or nil when it is not installed.
            public let path: String?
            public init(name: String, path: String?) { self.name = name; self.path = path }
        }
        public let cli: String
        /// The command that installs Darkbloom again, for the way back after `--keep-models`.
        public let installCommand: String
        /// The cluster service's launch agent files (`ClusterServiceAgent.installedLabels`); empty when it is not set up.
        public let clusterService: [String]
        public let services: [Service]
        public let items: [ProviderUninstallItem]
        public let pairing: ProviderUninstallPairing?
        /// Darkbloom things this command never removes, each with how to remove it (the fan helper, …).
        public let elsewhere: [String]

        public init(cli: String = BuildEnvironment.current.cliName,
                    installCommand: String = "curl -fsSL \(BuildEnvironment.current.coordinatorHTTPURL)/install.sh | bash",
                    clusterService: [String] = [], services: [Service], items: [ProviderUninstallItem],
                    pairing: ProviderUninstallPairing?, elsewhere: [String] = []) {
            self.cli = cli; self.installCommand = installCommand; self.clusterService = clusterService
            self.services = services; self.items = items; self.pairing = pairing; self.elsewhere = elsewhere
        }

        /// What `mode` deletes, in order.
        func removed(_ mode: Mode) -> [ProviderUninstallItem] {
            items.filter { $0.verdict == .remove && !(mode == .keepModels && $0.kind == .model) }
        }
        var models: [ProviderUninstallItem] { items.filter { $0.verdict == .remove && $0.kind == .model } }
        var kept: [ProviderUninstallItem] { items.filter { $0.verdict == .keep } }
        var refused: [ProviderUninstallItem] { items.filter { $0.verdict == .refused } }
        /// Disk space deleting `mode`'s items frees, with APFS clones counted once.
        func frees(_ mode: Mode) -> Int64 { uniqueBytes(removed(mode)) }
        var modelBytes: Int64 { uniqueBytes(models) }
    }

    public static let keychainLine = "Never touched: Keychain keys (Secure Enclave and App Attest); a new install replaces them."
    public static let choicePrompt = "  Choose 1 or 2 (Esc cancels): "

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

    static let chosenModelsLabel = "Models in the folder you chose"
    static let clusterStoreLabel = "Cluster model store"

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

    /// What no option deletes: folders outside Darkbloom's, Keychain keys, and what has its own uninstall.
    static func neverTouched(_ plan: Plan) -> [String] {
        plan.kept.map { "Never touched: \($0.label) (\(formatBytes($0.bytes)), \($0.path)): \($0.reason ?? "")" }
            + [keychainLine] + plan.elsewhere
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
        item.bytes > 0 ? "\(item.label)  \(formatBytes(item.bytes))  \(item.path)" : "\(item.label)  \(item.path)"
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
                                  cli: String = BuildEnvironment.current.cliName) -> Invocation {
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
            actions += plan.removed(mode).map { .init(action: "Delete \($0.label)", path: $0.path, bytes: $0.bytes) }
            let keptModels = mode == .keepModels ? plan.models : []
            return .init(mode: mode, actions: actions, frees: plan.frees(mode), kept: keptModels + plan.kept, refused: plan.refused)
        }
        return .init(modes: modePlans, neverTouched: [keychainLine] + plan.elsewhere,
                     otherMac: plan.pairing.map { otherMacLine($0, cli: plan.cli) })
    }
}
