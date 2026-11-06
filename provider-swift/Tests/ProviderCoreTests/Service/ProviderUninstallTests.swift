import DarkbloomClusterRemote
import Foundation
import Testing
@testable import ProviderCore

// `darkbloom uninstall` on a fake home: real files in a temporary root, the real provider, watchdog and cluster
// service agent removals through a fake launchctl, and recorded stand-ins for the drain, the pairing and the cable.
// Nothing here runs launchctl, a provider or a prompt, or reads the real home or Keychain.

private final class FakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private var calls: [[String]] = []

    init(loaded: Set<String>) { self.loaded = loaded }

    func run(_ arguments: [String]) throws -> LaunchctlControl.Output {
        lock.withLock {
            calls.append(arguments)
            let label = arguments.count > 1 ? String(arguments[1].split(separator: "/").last ?? "") : ""
            switch arguments.first {
            case "print":
                return loaded.contains(label) ? .init(status: 0, stdout: "", stderr: "")
                    : .init(status: 113, stdout: "", stderr: "Could not find service \"\(label)\" in domain for user gui: 501\n")
            case "bootout":
                loaded.remove(label)
                return .init(status: 0, stdout: "", stderr: "")
            case "disable", "enable":
                return .init(status: 0, stdout: "", stderr: "")
            default:
                return .init(status: 64, stdout: "", stderr: "unexpected launchctl \(arguments)\n")
            }
        }
    }

    var bootedOut: [String] { lock.withLock { calls.filter { $0.first == "bootout" }.map { String($0[1].split(separator: "/").last ?? "") } } }
    func load(_ label: String) { lock.withLock { _ = loaded.insert(label) } }
    var callCount: Int { lock.withLock { calls.count } }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

/// The cluster service holding this install's lock, as the run reads it (`Operations.runningClusterService`).
/// `cluster stop --service` (step 2) stops it when it is this install's or runs this build's command, as the real
/// stop does, unless it is told not to stop; a stop is written to `log`, the same log the deletions go to.
private final class FakeClusterService: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProviderUninstall.RunningClusterService?
    private let log: Calls
    private let stops: Bool

    init(_ running: ProviderUninstall.RunningClusterService, log: Calls, stops: Bool = true) {
        current = running; self.log = log; self.stops = stops
    }

    var running: ProviderUninstall.RunningClusterService? { lock.withLock { current } }

    func clusterStop() {
        guard stops, let running, running.owner == .thisInstall || running.isThisCLI else { return }
        log.add("stop cluster service \(running.pid)")
        lock.withLock { current = nil }
    }
}

private struct Fixture {
    static let pin = String(repeating: "ab", count: 32)
    static let ours = ".cache/huggingface/hub/models--org--ours-mlx"
    static let clusterLabel = ClusterServiceAgentPlan.labelPrefix + "0123456789ab"

    let root: URL
    let home: URL
    let outside: URL
    let paths: ProviderUninstallPaths
    let launchd: FakeLaunchd
    let calls = Calls()
    /// Every path the run asked to delete, in order.
    let deletes = Calls()

    var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    var desktopPlist: URL { agents.appendingPathComponent("io.darkbloom.desktop-api.plist") }
    var savedModels: URL { outside.appendingPathComponent("external-hub") }

    /// A provider Mac with every Darkbloom place filled, a saved model folder on "another volume" and another tool's model.
    static func make() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: ProviderUninstallPaths.canonical(base.path), isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        var paths = ProviderUninstallPaths(home: home, commandLinkDirectory: root.appendingPathComponent("usr/local/bin"))
        let fixture = Fixture(root: root, home: home, outside: root.appendingPathComponent("outside"), paths: paths,
                              launchd: FakeLaunchd(loaded: [LaunchAgent.label, WatchdogAgent.label, clusterLabel]))
        let install = paths.installDirectory.lastPathComponent
        let app = "\(install)/\(paths.appBundleName)/Contents/MacOS/\(paths.commandLink.lastPathComponent)"
        for file in [app, "\(install)/provider.log", "\(install)/cluster-setup/wizard.json",
                     "\(install)/cluster-pairing/pairings.json", "\(install)/auth_token",
                     "\(paths.configDirectory.path.dropFirst(home.path.count + 1))/provider.toml",
                     "\(paths.cacheDirectory.path.dropFirst(home.path.count + 1))/kv3/segment",
                     "\(Self.ours)/snapshots/rev1/.darkbloom-manifest.json", "\(Self.ours)/snapshots/rev1/model.safetensors",
                     ".cache/huggingface/hub/models--org--partial/snapshots/.local-staging-v2__org__partial/a.part",
                     ".cache/huggingface/hub/models--org--other-mlx/snapshots/rev1/model.safetensors",
                     ".cache/huggingface/hub/.artifact-writer-locks/models--org--ours-mlx",
                     ".cache/huggingface/darkbloom-cluster-models/org--ours/.darkbloom-manifest.json",
                     "Library/LaunchAgents/\(LaunchAgent.label).plist", "Library/LaunchAgents/\(WatchdogAgent.label).plist",
                     "Library/LaunchAgents/io.darkbloom.desktop-api.plist", "Library/LaunchAgents/\(clusterLabel).plist"] {
            try fixture.write(home.appendingPathComponent(file))
        }
        // The scanner's selected revision, and the cluster store's copy as `darkbloom cluster` makes it: an APFS clone.
        let ref = home.appendingPathComponent("\(Self.ours)/refs/main")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rev1".utf8).write(to: ref)
        try fixture.clone(home.appendingPathComponent("\(Self.ours)/snapshots/rev1/model.safetensors"),
                          to: home.appendingPathComponent(".cache/huggingface/darkbloom-cluster-models/org--ours/model.safetensors"))
        try fixture.link(home.appendingPathComponent("\(install)/bin/\(paths.commandLink.lastPathComponent)"),
                         to: "../\(paths.appBundleName)/Contents/MacOS/\(paths.commandLink.lastPathComponent)")
        try fixture.link(paths.commandLink, to: paths.installDirectory.appendingPathComponent("bin/\(paths.commandLink.lastPathComponent)").path)
        try fixture.write(fixture.savedModels.appendingPathComponent("models--org--big/snapshots/rev1/.darkbloom-manifest.json"))
        paths.savedModelCache = fixture.savedModels
        return Fixture(root: root, home: home, outside: fixture.outside, paths: paths, launchd: fixture.launchd)
    }

    func write(_ url: URL, bytes: Int = 8192) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func clone(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard clonefile(source.path, destination.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func link(_ url: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Every path under `url` (links not followed), to compare before and after.
    func tree(_ url: URL, excluding excluded: String? = nil) -> [String] {
        let all = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
        return all.filter { excluded == nil || !$0.hasPrefix(excluded!) }.sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The same Mac with `models location` set to `folder`.
    func choosingModels(_ folder: URL) -> Fixture {
        var paths = paths
        paths.savedModelCache = folder
        return Fixture(root: root, home: home, outside: outside, paths: paths, launchd: launchd)
    }

    var pairing: ProviderUninstallPairing {
        .init(peers: [.init(pin: Self.pin, name: "M3 Ultra, 512 GB")], otherMacName: "M3 Ultra, 512 GB", role: .leader)
    }

    func plan(pairing: ProviderUninstallPairing?) -> ProviderUninstall.Plan {
        let installed = { (name: String) in FileManager.default.fileExists(atPath: agents.appendingPathComponent(name).path) }
        let services = [("provider service", "\(LaunchAgent.label).plist"), ("watchdog service", "\(WatchdogAgent.label).plist"),
                        ("desktop API service", desktopPlist.lastPathComponent)]
        return .init(cli: "darkbloom",
                     clusterService: installed("\(Fixture.clusterLabel).plist") ? [agents.appendingPathComponent("\(Fixture.clusterLabel).plist").path] : [],
                     services: services.map { .init(name: $0.0, path: installed($0.1) ? agents.appendingPathComponent($0.1).path : nil) },
                     items: ProviderUninstall.inventory(paths), pairing: pairing)
    }

    func operations(drainFails: Bool = false, clusterFails: Bool = false, linkFails: Bool = false,
                    tokenUnconfirmed: Bool = false, providerRunning: Bool = true,
                    cluster: FakeClusterService? = nil, install: BuildEnvironment = .current) -> ProviderUninstall.Operations {
        let calls = calls, desktop = desktopPlist
        let free = Calls()
        return .init(
            stopServing: {
                calls.add("drain")
                if drainFails { throw ProviderUninstall.StepFailure("1 accepted request still running after 600 s") }
                return providerRunning ? .done() : .skipped("the provider service was not running")
            },
            stopClusterPart: {
                calls.add("cluster stop")
                if clusterFails { throw ProviderUninstall.StepFailure("the other Mac did not acknowledge the stop") }
                cluster?.clusterStop()
                return try ClusterServiceAgent.uninstall(environment: install).isEmpty ? .skipped("no cluster service on this Mac") : .done()
            },
            removeServices: [
                ("Remove the provider service", {
                    try ProviderUninstall.removeAgent(plist: LaunchAgent.plistPath(), loaded: LaunchAgent.isLoaded(),
                                                      uninstall: LaunchAgent.uninstall)
                }),
                ("Remove the watchdog service", {
                    try ProviderUninstall.removeAgent(plist: WatchdogAgent.plistPath(), loaded: WatchdogAgent.isLoaded(),
                                                      uninstall: WatchdogAgent.uninstall)
                }),
                ("Remove the desktop API service", {
                    try ProviderUninstall.removeAgent(plist: desktop, loaded: false,
                                                      uninstall: { try FileManager.default.removeItem(at: desktop) })
                }),
            ],
            servicesHandled: { calls.add("lease released") },
            revokeToken: {
                calls.add("revoke token")
                return tokenUnconfirmed ? .skipped("the coordinator did not confirm it (offline, or the token's issuer is unknown)")
                    : .done()
            },
            forget: { calls.add("forget \($0)") },
            removeCableSetup: {
                calls.add("link remove")
                if linkFails { throw ProviderUninstall.StepFailure("the macOS prompt was declined; nothing was changed") }
                return .done()
            },
            delete: { [deletes] in
                deletes.add($0.path)
                try FileManager.default.removeItem(at: $0)
            },
            availableBytes: {
                free.add("measured")
                return free.count("measured") == 1 ? 1_000_000_000 : 1_250_000_000
            },
            runningClusterService: { cluster?.running })
    }

    /// Runs with the fake home and the fake launchctl.
    func run(_ mode: ProviderUninstall.Mode, items: [ProviderUninstallItem]? = nil, pairing: ProviderUninstallPairing? = nil,
             cableKeptFor: BuildEnvironment? = nil, operations: ProviderUninstall.Operations? = nil) async -> ProviderUninstall.Report {
        await LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
            await LaunchctlControl.$runnerForTesting.withValue({ try launchd.run($0) }) {
                await ProviderUninstall.run(mode, items: items ?? ProviderUninstall.inventory(paths), pairing: pairing,
                                            cableKeptFor: cableKeptFor, operations: operations ?? self.operations())
            }
        }
    }
}

private func status(_ report: ProviderUninstall.Report, _ name: String) -> ProviderUninstall.Step.Status? {
    report.steps.first { $0.name == name }?.status
}

/// With `UNINSTALL_TRANSCRIPT_DIR` set, keeps what a person would read, with the fake root shown as `~`'s parent.
private func transcript(_ name: String, _ lines: [String], _ fixture: Fixture) {
    guard let directory = ProcessInfo.processInfo.environment["UNINSTALL_TRANSCRIPT_DIR"] else { return }
    let text = lines.joined(separator: "\n").replacingOccurrences(of: fixture.home.path, with: "~")
        .replacingOccurrences(of: fixture.root.path, with: "<root>") + "\n"
    try? text.write(toFile: directory + "/" + name + ".txt", atomically: true, encoding: .utf8)
}

/// The owner's Mac: the production and the DevNet app, each with its command, its own cluster files (pairing, setup,
/// device records, observability, saved setups) in its own folders, and its own cluster service agent, loaded. Returns
/// each install's cluster files and agent label.
private func installBoth(_ fixture: Fixture) throws -> [BuildEnvironment: (files: [URL], agent: String)] {
    var installed: [BuildEnvironment: (files: [URL], agent: String)] = [:]
    for install in [BuildEnvironment.prod, .dev] {
        let folder = install.installDirectory(home: fixture.home)
        let binary = folder.appendingPathComponent("\(install.appBundleName)/Contents/MacOS/\(install.cliName)")
        if !fixture.exists(binary) { try fixture.write(binary) }
        let bin = folder.appendingPathComponent("bin/\(install.cliName)")
        if !fixture.exists(bin) { try fixture.link(bin, to: "../\(install.appBundleName)/Contents/MacOS/\(install.cliName)") }
        try fixture.write(folder.appendingPathComponent("provider.log"))
        let paths = try ClusterUserPaths(homeDirectory: fixture.home, environment: install)
        let files = [paths.pairingDirectory.appendingPathComponent("pairings.json"), paths.setupDirectory.appendingPathComponent("wizard.json"),
                     paths.deviceDirectory.appendingPathComponent("link-alias.json"),
                     paths.observabilityDirectory.appendingPathComponent("device-index.json"),
                     paths.configurationsDirectory.appendingPathComponent("0123.cluster.json")]
        for file in files { try fixture.write(file) }
        // The agent `install`'s `darkbloom cluster` writes: its label, and its program in its own app.
        let agent = ClusterServiceAgentPlan.label(executablePath: binary.path, environment: install)
        let plist = try ClusterServiceAgentPlan.encoded(ClusterServiceAgentPlan.propertyList(
            label: agent, programArguments: ClusterServiceAgentPlan.programArguments(executablePath: binary.path, serviceOptions: []),
            logPath: paths.setupDirectory.appendingPathComponent("service.log").path, environment: [:]))
        try FileManager.default.createDirectory(at: fixture.agents, withIntermediateDirectories: true)
        try plist.write(to: fixture.agents.appendingPathComponent("\(agent).plist"))
        fixture.launchd.load(agent)
        installed[install] = (files, agent)
    }
    return installed
}

/// Each of `files` with its bytes (empty when it is gone), to tell "untouched" from "rewritten" or "deleted".
private func contents(_ files: [URL]) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: files.map { ($0.path, (try? Data(contentsOf: $0)) ?? Data()) })
}

@Suite("darkbloom uninstall")
struct ProviderUninstallTests {
    @Test("(a) keep models: everything else goes, unpaired and cable undone; the models stay and are found again")
    func keepModelsRemovesEverythingElse() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let hub = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        let models = [hub.appendingPathComponent("models--org--ours-mlx"), hub.appendingPathComponent("models--org--partial"),
                      hub.appendingPathComponent(".artifact-writer-locks"), fixture.paths.clusterModelStore]
        let before = models.map { fixture.tree($0) }
        let receipts = [Fixture.ours + "/refs/main", Fixture.ours + "/snapshots/rev1/.darkbloom-manifest.json",
                        ".cache/huggingface/darkbloom-cluster-models/org--ours/.darkbloom-manifest.json"]
            .map { try? Data(contentsOf: fixture.home.appendingPathComponent($0)) }
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.keepModels, items: plan.items, pairing: fixture.pairing)

        #expect(!report.failed, "\(report.steps)")
        #expect(fixture.tree(fixture.agents).isEmpty, "provider, watchdog, desktop API and cluster agents are gone")
        #expect(Set(fixture.launchd.bootedOut) == [LaunchAgent.label, WatchdogAgent.label, Fixture.clusterLabel])
        #expect(fixture.calls.all == ["drain", "cluster stop", "lease released", "revoke token", "forget \(Fixture.pin)",
                                      "link remove"], "unpaired and the cable undone, as for everything")
        for gone in [fixture.paths.installDirectory, fixture.paths.configDirectory, fixture.paths.cacheDirectory,
                     fixture.paths.commandLink] {
            #expect(!fixture.exists(gone), "\(gone.path) is deleted")
        }
        #expect(models.map { fixture.tree($0) } == before, "every model folder, lock and the cluster store stay as they were")
        #expect(receipts.allSatisfy { $0 != nil })
        #expect([Fixture.ours + "/refs/main", Fixture.ours + "/snapshots/rev1/.darkbloom-manifest.json",
                 ".cache/huggingface/darkbloom-cluster-models/org--ours/.darkbloom-manifest.json"]
            .map { try? Data(contentsOf: fixture.home.appendingPathComponent($0)) } == receipts, "receipts and refs are untouched")
        // A reinstall's discovery: the scanner over the same cache finds the model again.
        #expect(ModelScanner.scanAllModels(in: hub, environment: [:]).map(\.id).contains("org/ours-mlx"))
        #expect(fixture.exists(fixture.savedModels.appendingPathComponent("models--org--big/snapshots/rev1/.darkbloom-manifest.json")))
        #expect(!report.steps.contains { $0.name.hasPrefix("Delete Model") || $0.name == "Delete Cluster model store" })
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("keep-models-summary-leader", summary, fixture)
        #expect(summary.first == "Darkbloom is removed from this Mac; its models are kept.")
        #expect(summary.contains { $0.hasPrefix("Kept: 2 models and the cluster model store, ") && $0.contains(hub.path) })
        #expect(summary.contains("To come back: run `curl -fsSL \(BuildEnvironment.current.coordinatorHTTPURL)/install.sh | bash`, "
            + "then `darkbloom start` or `darkbloom cluster`; the models are found automatically."))
        #expect(summary.contains { $0.hasPrefix("Models in the folder you chose are not found automatically") })
        #expect(summary.contains(ProviderUninstall.keychainLine))
        #expect(summary.contains { $0.hasPrefix("Never touched: Models in the folder you chose") && $0.contains(fixture.savedModels.path) })
    }

    @Test("(b) everything: data, models, the app and the command link go; revoke, forget and link remove run once each")
    func everythingRemovesDarkbloomData() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let hub = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.everything, items: plan.items, pairing: fixture.pairing)

        #expect(!report.failed, "\(report.steps)")
        for gone in [fixture.paths.installDirectory, fixture.paths.configDirectory, fixture.paths.cacheDirectory,
                     hub.appendingPathComponent("models--org--ours-mlx"), hub.appendingPathComponent("models--org--partial"),
                     hub.appendingPathComponent(".artifact-writer-locks"), fixture.paths.clusterModelStore,
                     fixture.paths.commandLink] {
            #expect(!fixture.exists(gone), "\(gone.path) is deleted")
        }
        #expect(fixture.exists(hub.appendingPathComponent("models--org--other-mlx/snapshots/rev1/model.safetensors")),
                "another tool's model in the shared cache stays")
        #expect(fixture.exists(fixture.savedModels.appendingPathComponent("models--org--big/snapshots/rev1/.darkbloom-manifest.json")),
                "models in the folder the person chose stay")
        #expect(fixture.calls.count("revoke token") == 1)
        #expect(fixture.calls.count("forget \(Fixture.pin)") == 1)
        #expect(fixture.calls.count("link remove") == 1)
        #expect(fixture.calls.all.firstIndex(of: "forget \(Fixture.pin)")! < fixture.calls.all.firstIndex(of: "link remove")!,
                "the other Mac is told over the cable before the cable's setup is undone")
        #expect(report.steps.last?.name == "Delete " + ProviderUninstall.installFolderLabel,
                "the folder with the running app goes last")
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("everything-summary-leader", summary, fixture)
        #expect(summary.first == "Darkbloom is removed from this Mac.")
        #expect(summary.contains { $0.hasPrefix("Space freed: 250 MB (this disk had 1 GB free, now 1.25 GB") })
        #expect(summary.contains { $0.hasPrefix("Never touched: Models in the folder you chose") && $0.contains(fixture.savedModels.path) })
        #expect(summary.contains(ProviderUninstall.keychainLine))
        #expect(!summary.contains { $0.hasPrefix("To come back") })
    }

    @Test("(c) dry run, both choices: every action and path with sizes, and nothing changes")
    func dryRunChangesNothing() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let before = fixture.tree(fixture.root)
        let plan = fixture.plan(pairing: fixture.pairing)
        let everything = ProviderUninstall.dryRun(plan, mode: .everything)
        let keepModels = ProviderUninstall.dryRun(plan, mode: .keepModels)
        transcript("screen", ProviderUninstall.screen(plan) + [ProviderUninstall.choicePrompt], fixture)
        transcript("dry-run-everything", everything, fixture)
        transcript("dry-run-keep-models", keepModels, fixture)

        #expect(fixture.tree(fixture.root) == before)
        #expect(fixture.launchd.callCount == 0, "nothing asked launchd")
        #expect(fixture.calls.all.isEmpty)
        for (lines, mode) in [(everything, ProviderUninstall.Mode.everything), (keepModels, .keepModels)] {
            let text = lines.joined(separator: "\n")
            for action in ["Stop serving on this Mac",
                           "Stop this Mac's cluster part and remove its service, as `darkbloom cluster stop --service`: "
                            + "\(fixture.agents.path)/\(Fixture.clusterLabel).plist",
                           "Remove the provider service: \(fixture.agents.path)/\(LaunchAgent.label).plist",
                           "Remove the watchdog service: \(fixture.agents.path)/\(WatchdogAgent.label).plist",
                           "Remove the desktop API service: \(fixture.desktopPlist.path)",
                           "Revoke this Mac's account token, as `darkbloom logout` does (best effort)",
                           "Forget the pairing with M3 Ultra, 512 GB", "Undo the cable port setup",
                           "Delete Settings", "Delete Darkbloom folder"] {
                #expect(text.contains(action), "\(mode): \(action)")
            }
            for item in plan.items where item.verdict == .remove {
                #expect(text.contains("Delete \(ProviderUninstall.row(item))") == (mode == .everything || item.kind != .model),
                        "\(mode): \(item.label)")
            }
            #expect(text.contains("Never touched: Models in the folder you chose"))
        }
        #expect(keepModels.contains { $0.hasPrefix("  Kept: 2 models and the cluster model store") })
        let screen = ProviderUninstall.screen(plan)
        #expect(Array(screen.prefix(6)) == ["Uninstall Darkbloom from this Mac", "",
            "  1) Remove everything",
            "     The app, settings, pairing, logs and the models not kept below · frees \(ProviderUninstall.formatBytes(plan.frees(.everything)))",
            "  2) Keep models",
            "     Removes everything else; a reinstall reuses the \(ProviderUninstall.formatBytes(plan.modelBytes)) of models"])
        #expect(ProviderUninstall.choicePrompt == "  Choose 1 or 2 (Esc cancels): ")
        // Pressing 1 asks once more, naming what can't come back.
        let question = ProviderUninstall.everythingQuestion(plan)
        transcript("everything-question", [question], fixture)
        #expect(question == "  Remove everything, including \(ProviderUninstall.formatBytes(plan.modelBytes)) of models? "
            + "This can't be undone. [y/N]: ")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(ProviderUninstall.dryRunDocument(plan, modes: ProviderUninstall.Mode.allCases))
        transcript("dry-run-json", [String(decoding: json, as: UTF8.self)], fixture)
        let document = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(document["schema"] as? String == "darkbloom_uninstall_plan_v1")
        #expect((document["modes"] as? [[String: Any]])?.map { $0["mode"] as? String } == ["everything", "keep-models"])
    }

    @Test("sizes count an APFS clone once, and not at all while a clone outside stays")
    func clonedModelIsCountedOnce() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let weights = fixture.home.appendingPathComponent("\(Fixture.ours)/snapshots/rev1/model.safetensors")
        let storeCopy = fixture.paths.clusterModelStore.appendingPathComponent("org--ours/model.safetensors")
        for url in [storeCopy, weights] { try FileManager.default.removeItem(at: url) }
        try Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }).write(to: weights)
        try fixture.clone(weights, to: storeCopy)
        let items = ProviderUninstall.inventory(fixture.paths)
        let model = try #require(items.first { $0.label == "Model org/ours-mlx" })
        let store = try #require(items.first { $0.label == "Cluster model store" })
        #expect(model.bytes >= 4 << 20 && store.bytes >= 4 << 20, "each item shows its own size")
        let both = ProviderUninstall.uniqueBytes([model, store])
        #expect(both == model.bytes + store.bytes - (4 << 20), "the clone's 4 MiB are counted once")
        let plan = fixture.plan(pairing: nil)
        #expect(plan.modelBytes == ProviderUninstall.uniqueBytes(plan.models))
        #expect(plan.frees(.everything) == plan.items.filter { $0.verdict == .remove }.reduce(0) { $0 + $1.bytes } - (4 << 20))
        // A third clone outside Darkbloom's folders keeps those blocks in use: deleting both frees none of them.
        try fixture.clone(weights, to: fixture.outside.appendingPathComponent("my-copy.safetensors"))
        let again = ProviderUninstall.inventory(fixture.paths).filter { [model.label, store.label].contains($0.label) }
        #expect(ProviderUninstall.uniqueBytes(again) == model.bytes + store.bytes - 2 * (4 << 20))
    }

    @Test("(d) a link or a path outside Darkbloom's folders is refused and left as it is")
    func outsideTargetsAreRefused() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let elsewhere = fixture.outside.appendingPathComponent("elsewhere/keep.txt")
        try fixture.write(elsewhere)
        // A link inside Darkbloom's folder: removing the folder removes the link, never what it points to.
        try fixture.link(fixture.paths.installDirectory.appendingPathComponent("models"), to: elsewhere.deletingLastPathComponent().path)
        // A model folder that is a link to another disk, with Darkbloom's receipt there.
        let linkedModel = fixture.outside.appendingPathComponent("linked-model")
        try fixture.write(linkedModel.appendingPathComponent("snapshots/rev1/.darkbloom-manifest.json"))
        let hubLink = fixture.home.appendingPathComponent(".cache/huggingface/hub/models--org--linked")
        try fixture.link(hubLink, to: linkedModel.path)
        // Settings moved to another folder and linked back.
        let movedSettings = fixture.outside.appendingPathComponent("dotfiles-darkbloom")
        try FileManager.default.moveItem(at: fixture.paths.configDirectory, to: movedSettings)
        try fixture.link(fixture.paths.configDirectory, to: movedSettings.path)
        // A command link that is not the installer's.
        try FileManager.default.removeItem(at: fixture.paths.commandLink)
        try fixture.link(fixture.paths.commandLink, to: fixture.outside.appendingPathComponent("other-tool").path)

        let items = ProviderUninstall.inventory(fixture.paths)
        let refused = Dictionary(uniqueKeysWithValues: items.filter { $0.verdict == .refused }.map { ($0.path, $0.reason ?? "") })
        #expect(refused[hubLink.path]?.contains("outside Darkbloom's folders") == true)
        #expect(refused[fixture.paths.configDirectory.path]?.contains("resolves to \(movedSettings.path)") == true)
        #expect(refused[fixture.paths.commandLink.path] == "it is not the link Darkbloom's installer made")

        let report = await fixture.run(.everything, items: items)
        #expect(fixture.exists(elsewhere), "the file behind the link inside ~/.darkbloom stays")
        #expect(fixture.exists(linkedModel.appendingPathComponent("snapshots/rev1/.darkbloom-manifest.json")))
        #expect(fixture.exists(hubLink) && fixture.exists(fixture.paths.configDirectory) && fixture.exists(fixture.paths.commandLink),
                "refused links are not removed either")
        #expect(fixture.exists(movedSettings.appendingPathComponent("provider.toml")))
        #expect(!fixture.exists(fixture.paths.installDirectory))
        #expect(report.steps.filter { $0.detail?.hasPrefix("not removed: ") == true }.count == 3)
        #expect(status(report, "Delete Settings") == .skipped)
        // What it refused is still Darkbloom's: the summary does not call it removed, and the command exits 1.
        #expect(report.incomplete && !report.failed)
        let summary = ProviderUninstall.summary(report, plan: fixture.plan(pairing: nil))
        transcript("everything-summary-settings-link", summary, fixture)
        #expect(summary.first == "Darkbloom is not fully removed from this Mac: some of its folders were not removed (see below).")
        #expect(summary.contains("  skipped  Delete Settings: not removed: it resolves to \(movedSettings.path), outside Darkbloom's folders"))
        // A command link the installer did not make is not Darkbloom's: leaving only that leaves nothing of Darkbloom's.
        let linkOnly = ProviderUninstall.Report(mode: .everything, steps: report.steps.filter { $0.name.hasPrefix("Delete The ") },
                                                availableBefore: nil, availableAfter: nil)
        #expect(linkOnly.steps.count == 1 && !linkOnly.incomplete)
    }

    @Test("blocker: a model folder the person chose inside ~/.darkbloom is kept in both modes, named, and the rest goes")
    func chosenModelsInsideDarkbloomFolderAreKept() async throws {
        for mode in ProviderUninstall.Mode.allCases {
            let base = try Fixture.make()
            defer { base.remove() }
            // The validator's case: `darkbloom models location ~/.darkbloom/models`, and the store the provider puts beside it.
            let chosen = base.paths.installDirectory.appendingPathComponent("models", isDirectory: true)
            let model = chosen.appendingPathComponent("models--org--chosen/snapshots/rev1/model.safetensors")
            try base.write(model)
            try base.write(chosen.appendingPathComponent("models--org--chosen/snapshots/rev1/.darkbloom-manifest.json"))
            let store = base.paths.installDirectory.appendingPathComponent("darkbloom-cluster-models/org--chosen/model.safetensors")
            try base.clone(model, to: store)
            let fixture = base.choosingModels(chosen)
            let plan = fixture.plan(pairing: nil)
            let screen = ProviderUninstall.screen(plan)
            let dryRun = ProviderUninstall.dryRun(plan, mode: mode)
            transcript("screen-chosen-inside", screen + [ProviderUninstall.choicePrompt], fixture)
            transcript("dry-run-\(mode.rawValue)-chosen-inside", dryRun, fixture)
            for lines in [screen, dryRun] {
                #expect(lines.contains { $0.contains("Kept: Models in the folder you chose") && $0.contains(chosen.path) }, "\(mode)")
                #expect(lines.contains { $0.contains("Kept: Cluster model store beside the folder you chose") }, "\(mode)")
            }
            #expect(dryRun.contains { $0.contains("Delete Darkbloom folder") && $0.contains("except the models you chose") }, "\(mode)")
            let document = ProviderUninstall.dryRunDocument(plan, modes: [mode]).modes[0]
            #expect(document.actions.contains {
                $0.action.hasSuffix(", except the models you chose") && $0.path == fixture.paths.installDirectory.path
            }, "\(mode): the JSON names the exception too")
            #expect(document.kept.contains { $0.path == chosen.path }, "\(mode)")

            let report = await fixture.run(mode, items: plan.items, pairing: nil)
            #expect(fixture.exists(model) && fixture.exists(store), "\(mode): the chosen folder and the store beside it stay")
            for gone in [fixture.paths.appBundleName, "provider.log", "auth_token", "cluster-pairing", "bin"] {
                #expect(!fixture.exists(fixture.paths.installDirectory.appendingPathComponent(gone)), "\(mode): \(gone) is deleted")
            }
            #expect(!fixture.exists(fixture.paths.configDirectory), "\(mode): settings are deleted")
            #expect(fixture.deletes.all.last == fixture.paths.installDirectory.appendingPathComponent(fixture.paths.appBundleName).path,
                    "\(mode): the app is deleted last")
            #expect(!report.failed && !report.incomplete, "\(mode): \(report.steps)")
            let summary = ProviderUninstall.summary(report, plan: plan)
            transcript("\(mode.rawValue)-summary-chosen-inside", summary, fixture)
            #expect(summary.contains { $0.hasPrefix("Kept: Models in the folder you chose") && $0.contains(chosen.path) })
            #expect(summary.contains { $0.hasPrefix("Kept: Cluster model store beside the folder you chose") })
        }
    }

    @Test("the cluster model store beside a chosen model folder outside Darkbloom's folders is listed and never touched")
    func storeBesideAChosenFolderIsListed() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let store = fixture.savedModels.deletingLastPathComponent().appendingPathComponent("darkbloom-cluster-models/org--big/model.safetensors")
        try fixture.write(store)
        let plan = fixture.plan(pairing: nil)
        for mode in ProviderUninstall.Mode.allCases {
            #expect(ProviderUninstall.dryRun(plan, mode: mode).contains {
                $0.hasPrefix("  Never touched: Cluster model store beside the folder you chose") && $0.contains(store.deletingLastPathComponent().deletingLastPathComponent().path)
            }, "\(mode)")
        }
        _ = await fixture.run(.everything, items: plan.items, pairing: nil)
        #expect(fixture.exists(store))
    }

    @Test("beside the other install, only this install's pairing, setup, files and cluster service go; the other's and the cable port setup stay, both ways")
    func besideTheOtherInstallOnlyItsOwnClusterGoes() async throws {
        for (this, other) in [(BuildEnvironment.dev, BuildEnvironment.prod), (.prod, .dev)] {
            let fixture = try Fixture.make()
            defer { fixture.remove() }
            let installed = try installBoth(fixture)
            let own = try #require(installed[this]), theirs = try #require(installed[other])
            let before = contents(theirs.files)
            let paths = ProviderUninstallPaths(home: fixture.home, environment: this,
                                               commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
            #expect(paths.otherEnvironment == other, "\(this)")
            let ownPlist = fixture.agents.appendingPathComponent("\(own.agent).plist").path
            let plan = LaunchctlControl.$homeDirectoryForTesting.withValue(fixture.home) {
                ProviderUninstall.Plan(cli: this.cliName, clusterService: ClusterServiceAgent.installedLabels(environment: this)
                                           .map { ClusterServiceAgent.plistPath(label: $0).path },
                                       services: [], items: ProviderUninstall.inventory(paths), pairing: fixture.pairing,
                                       cableKeptFor: paths.otherEnvironment)
            }
            #expect(plan.clusterService.contains(ownPlist), "\(this): its own agent is listed")
            #expect(!plan.clusterService.contains { $0.hasSuffix("\(theirs.agent).plist") }, "\(this): the other's agent is not")
            let otherName = ProviderUninstall.installName(other)
            let cable = "Kept: this Mac's cable port setup: \(otherName) on this Mac may use the same cable. Run `\(other.cliName) uninstall` there to undo it"
            let screen = ProviderUninstall.screen(plan), dryRun = ProviderUninstall.dryRun(plan, mode: .everything)
            transcript("screen-\(this.rawValue)-beside-\(other.rawValue)", screen + [ProviderUninstall.choicePrompt], fixture)
            transcript("dry-run-\(this.rawValue)-beside-\(other.rawValue)", dryRun, fixture)
            #expect(screen.contains("  \(cable)") && dryRun.contains("  \(cable)"), "\(this)")
            #expect(screen[3].hasPrefix("     The app, settings, pairing and logs"), "\(this): its own pairing goes")
            #expect(dryRun.contains { $0.contains("Forget the pairing with M3 Ultra, 512 GB") }, "\(this)")
            #expect(dryRun.contains { $0.contains(ProviderUninstall.clusterStep) && $0.contains(ownPlist) }, "\(this)")
            #expect(!dryRun.contains { $0.contains(ProviderUninstall.cableStep) }, "\(this): the cable step does not run")
            let document = ProviderUninstall.dryRunDocument(plan, modes: [.everything])
            #expect(document.neverTouched.contains(cable) && document.otherMac != nil, "\(this)")
            #expect(document.modes[0].actions.contains { $0.action.hasPrefix("Forget the pairing") }
                    && !document.modes[0].actions.contains { $0.action == ProviderUninstall.cableStep }, "\(this)")

            let report = await fixture.run(.everything, items: plan.items, pairing: fixture.pairing, cableKeptFor: plan.cableKeptFor,
                                           operations: fixture.operations(install: this))
            #expect(fixture.calls.all.contains("cluster stop") && fixture.calls.all.contains("forget \(Fixture.pin)"),
                    "\(this): its own pair stops and its own pairing is forgotten")
            #expect(!fixture.calls.all.contains("link remove"), "\(this): the cable port setup stays")
            #expect(fixture.launchd.bootedOut.contains(own.agent) && !fixture.exists(URL(fileURLWithPath: ownPlist)), "\(this)")
            #expect(!fixture.launchd.bootedOut.contains(theirs.agent)
                    && fixture.exists(fixture.agents.appendingPathComponent("\(theirs.agent).plist")),
                    "\(this): the other install's agent stays loaded and installed")
            for file in own.files { #expect(!fixture.exists(file), "\(this): its own \(file.lastPathComponent) goes") }
            #expect(contents(theirs.files) == before, "\(this): the other install's cluster files are untouched")
            #expect(fixture.exists(other.installDirectory(home: fixture.home).appendingPathComponent(other.appBundleName)), "\(this)")
            #expect(!report.failed && !report.incomplete, "\(this): \(report.steps)")
            let summary = ProviderUninstall.summary(report, plan: plan)
            transcript("\(this.rawValue)-summary-beside-\(other.rawValue)", summary, fixture)
            let thisName = this == .prod ? "The production Darkbloom" : this.appDisplayName
            #expect(summary.first == "\(thisName) is removed from this Mac.", "\(this)")
            #expect(summary.contains("  skipped  \(ProviderUninstall.cableStep): kept: \(otherName) on this Mac may use the same cable"),
                    "\(this)")
            #expect(summary.contains(cable), "\(this)")
            #expect(summary.last?.hasPrefix("The other Mac (M3 Ultra, 512 GB) followed this one: run `\(this.cliName) uninstall` there too")
                    == true, "\(this): its pair is gone, so the other Mac is told")
        }
    }

    @Test("an agent of production's shape is DevNet's only when an older DevNet wrote it, and then never production's")
    func legacyAgentsAreToldApartByTheirProgram() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try installBoth(fixture)
        // The label an older DevNet build gave its own job: production's prefix, digest of DevNet's app, program in DevNet's app.
        let devBinary = BuildEnvironment.dev.installDirectory(home: fixture.home).appendingPathComponent("Darkbloom Dev.app/Contents/MacOS/darkbloom-dev")
        let legacy = ClusterServiceAgentPlan.label(executablePath: devBinary.path, environment: .prod)
        let plist = try ClusterServiceAgentPlan.encoded(ClusterServiceAgentPlan.propertyList(
            label: legacy, programArguments: ClusterServiceAgentPlan.programArguments(executablePath: devBinary.path, serviceOptions: []),
            logPath: "/dev/null", environment: [:]))
        try plist.write(to: fixture.agents.appendingPathComponent("\(legacy).plist"))
        fixture.launchd.load(legacy)
        // A job of production's shape whose program can't be read stays production's, as before; never DevNet's.
        let unreadable = BuildEnvironment.prod.clusterServiceLabelPrefix + "0123456789ac"
        try fixture.write(fixture.agents.appendingPathComponent("\(unreadable).plist"))
        LaunchctlControl.$homeDirectoryForTesting.withValue(fixture.home) {
            #expect(ClusterServiceAgent.installedLabels(environment: .dev).contains(legacy), "DevNet's older job is DevNet's")
            #expect(!ClusterServiceAgent.installedLabels(environment: .prod).contains(legacy), "and never production's")
            #expect(ClusterServiceAgent.installedLabels(environment: .prod).contains(unreadable))
            #expect(!ClusterServiceAgent.installedLabels(environment: .dev).contains(unreadable))
        }
    }

    @Test("B11: a cluster service running without its login agent is named in the dry run")
    func runningClusterServiceWithoutAgentIsNamed() {
        for running in [false, true] {
            let plan = ProviderUninstall.Plan(cli: "darkbloom", clusterServiceRunning: running, services: [], items: [], pairing: nil)
            #expect(ProviderUninstall.dryRun(plan, mode: .everything)[2] == "  2. Stop this Mac's cluster part and remove its service, "
                + "as `darkbloom cluster stop --service`: "
                + (running ? "a cluster service is running on this Mac: this stops a `darkbloom cluster service`, and nothing is deleted "
                    + "while any other runs" : "no cluster service on this Mac"))
        }
        #expect(ProviderUninstall.installFolderLabel == "Darkbloom folder: the app, logs, pairing and cluster setup",
                "every install keeps its own pairing and cluster setup in its own folder")
    }

    @Test("F3: a models folder that is ~/.darkbloom itself keeps the app, and the summary says Darkbloom is not fully removed")
    func modelsFolderThatIsTheAppFolderIsNotCalledRemoved() async throws {
        let base = try Fixture.make()
        defer { base.remove() }
        let install = base.paths.installDirectory
        try base.write(install.appendingPathComponent("models--org--chosen/snapshots/rev1/.darkbloom-manifest.json"))
        let fixture = base.choosingModels(install)
        let plan = fixture.plan(pairing: nil)
        let cli = fixture.paths.commandLink.lastPathComponent
        let advice = "run `\(install.path)/bin/\(cli) uninstall` again"
        let dryRun = ProviderUninstall.dryRun(plan, mode: .everything)
        transcript("dry-run-everything-models-in-app-folder", dryRun, fixture)
        #expect(dryRun.contains { $0.hasPrefix("  Not deleted: Darkbloom folder") && $0.contains("it is the models folder you chose") })
        let report = await fixture.run(.everything, items: plan.items, pairing: nil)
        #expect(fixture.exists(install.appendingPathComponent(fixture.paths.appBundleName)), "the folder you chose stays, app included")
        #expect(!dryRun.contains { $0.contains("Not deleted: The `\(cli)` command link") }, "the link is not in the folder")
        #expect(!fixture.exists(fixture.paths.commandLink), "the command link, outside the folder, goes")
        #expect(report.incomplete && !report.failed, "\(report.steps)")
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("everything-summary-models-in-app-folder", summary, fixture)
        #expect(summary.first == "Darkbloom is not fully removed from this Mac: its app folder is your models folder, so it was kept (see below).")
        #expect(summary.contains { $0.contains("skipped  Delete Darkbloom folder") && $0.contains("not removed: it is the models folder you chose")
            && $0.contains(advice) }, "the summary says what to do")
    }

    @Test("B16: this install's cluster service, one a session started too, stops at step 2 before anything is deleted")
    func thisInstallsRunningServiceStopsBeforeDeleting() async throws {
        for (this, other) in [(BuildEnvironment.dev, BuildEnvironment.prod), (.prod, .dev)] {
            let fixture = try Fixture.make()
            defer { fixture.remove() }
            _ = try installBoth(fixture)
            let paths = ProviderUninstallPaths(home: fixture.home, environment: this,
                                               commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
            // `darkbloom-dev cluster service` started from a session, with no launchd agent, as on the c3 member.
            let binary = this.installDirectory(home: fixture.home).appendingPathComponent("\(this.appBundleName)/Contents/MacOS/\(this.cliName)")
            let running = ProviderUninstall.RunningClusterService(pid: 4242, executable: binary.path,
                owner: ProviderUninstall.owner(ofExecutable: binary.path, paths: paths), isThisCLI: true)
            #expect(running.owner == .thisInstall, "\(this)")
            let report = await fixture.run(.keepModels, items: ProviderUninstall.inventory(paths), pairing: fixture.pairing, cableKeptFor: other,
                                           operations: fixture.operations(providerRunning: false,
                                                                          cluster: FakeClusterService(running, log: fixture.deletes), install: this))
            let log = fixture.deletes.all
            #expect(log.first == "stop cluster service 4242" && log.count > 1, "\(this): stopped before the first deletion: \(log)")
            #expect(fixture.exists(other.installDirectory(home: fixture.home).appendingPathComponent(other.appBundleName)), "\(this)")
            #expect(!report.failed, "\(this): \(report.steps)")
        }
    }

    @Test("B16: a running cluster service that can't be told apart, or that did not stop, keeps every file; exit 1")
    func unknownOrUnstoppedServiceRefusesToDelete() async throws {
        // Beside the other install: a service from neither app.
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try installBoth(fixture)
        let paths = ProviderUninstallPaths(home: fixture.home, environment: .dev,
                                           commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
        let elsewhere = fixture.outside.appendingPathComponent("build/darkbloom-dev").path
        let unknown = ProviderUninstall.RunningClusterService(
            pid: 999, executable: elsewhere, owner: ProviderUninstall.owner(ofExecutable: elsewhere, paths: paths))
        #expect(unknown.owner == .unknown)
        #expect(ProviderUninstall.owner(ofExecutable: nil, paths: paths) == .unknown)
        let plan = ProviderUninstall.Plan(cli: "darkbloom-dev", runningClusterService: unknown, services: [],
                                          items: ProviderUninstall.inventory(paths), pairing: fixture.pairing, cableKeptFor: .prod)
        let report = await fixture.run(.everything, items: plan.items, pairing: fixture.pairing, cableKeptFor: .prod,
                                       operations: fixture.operations(cluster: FakeClusterService(unknown, log: fixture.deletes), install: .dev))
        #expect(fixture.deletes.all.isEmpty, "nothing is stopped or deleted: \(fixture.deletes.all)")
        #expect(report.failed)
        let refusal = "nothing is deleted while it runs. Stop it first with `darkbloom-dev cluster stop --service`, then run `darkbloom-dev uninstall` again"
        #expect(ProviderUninstall.summary(report, plan: plan).contains { $0.contains("failed") && $0.contains("pid 999") }, "\(report.steps)")
        #expect(ProviderUninstall.stillRunningReason(unknown, cli: "darkbloom-dev").hasSuffix(refusal))
        #expect(ProviderUninstall.dryRun(plan, mode: .everything).contains {
            $0.contains("under another name, is running (pid 999); this does not stop it, and nothing is deleted while it runs") })

        // One install: `cluster stop --service` ran, but this install's service still holds the lock.
        let single = try Fixture.make()
        defer { single.remove() }
        let binary = single.paths.installDirectory.appendingPathComponent("\(single.paths.appBundleName)/Contents/MacOS/\(single.paths.commandLink.lastPathComponent)")
        let stuck = ProviderUninstall.RunningClusterService(
            pid: 31, executable: binary.path, owner: ProviderUninstall.owner(ofExecutable: binary.path, paths: single.paths))
        #expect(stuck.owner == .thisInstall)
        let alone = await single.run(.everything, pairing: single.pairing,
                                     operations: single.operations(cluster: FakeClusterService(stuck, log: single.deletes, stops: false)))
        #expect(single.deletes.all.isEmpty, "nothing is deleted under it: \(single.deletes.all)")
        #expect(alone.failed && status(alone, ProviderUninstall.stillRunningStep) == .failed, "\(alone.steps)")
        #expect(single.exists(single.paths.installDirectory.appendingPathComponent(single.paths.appBundleName)))
    }

    @Test("m1: a cluster service started through a link is told apart by where the link leads")
    func linkedExecutablesAreResolvedBeforeTellingWhose() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try installBoth(fixture)
        for (this, other) in [(BuildEnvironment.dev, BuildEnvironment.prod), (.prod, .dev)] {
            let paths = ProviderUninstallPaths(home: fixture.home, environment: this,
                                               commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
            // `~/.darkbloom-dev/bin/darkbloom-dev cluster service`: the kernel records the link, not the app binary.
            let ownLink = this.installDirectory(home: fixture.home).appendingPathComponent("bin/\(this.cliName)").path
            let otherLink = other.installDirectory(home: fixture.home).appendingPathComponent("bin/\(other.cliName)").path
            #expect(ProviderUninstall.owner(ofExecutable: ownLink, paths: paths) == .thisInstall, "\(this)")
            #expect(ProviderUninstall.owner(ofExecutable: otherLink, paths: paths) == .otherInstall(ProviderUninstall.installName(other)),
                    "\(this)")
            // A link elsewhere that leads into the other install's app.
            let elsewhere = fixture.outside.appendingPathComponent("links/\(other.cliName)")
            try fixture.link(elsewhere, to: other.installDirectory(home: fixture.home)
                .appendingPathComponent("\(other.appBundleName)/Contents/MacOS/\(other.cliName)").path)
            #expect(ProviderUninstall.owner(ofExecutable: elsewhere.path, paths: paths) == .otherInstall(ProviderUninstall.installName(other)),
                    "\(this)")
            try FileManager.default.removeItem(at: elsewhere)
        }
    }

    @Test("n2: a cluster service that starts again during the steps after step 2 still keeps every file")
    func stillRunningCheckIsRightBeforeTheFirstDeletion() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let binary = fixture.paths.installDirectory
            .appendingPathComponent("\(fixture.paths.appBundleName)/Contents/MacOS/\(fixture.paths.commandLink.lastPathComponent)")
        let running = ProviderUninstall.RunningClusterService(pid: 51, executable: binary.path, owner: .thisInstall)
        // It starts again while the cable step waits for its password.
        let started = Calls()
        var operations = fixture.operations()
        let cable = operations.removeCableSetup
        operations.removeCableSetup = { started.add("started"); return try cable() }
        operations.runningClusterService = { started.all.isEmpty ? nil : running }
        let report = await fixture.run(.everything, pairing: fixture.pairing, operations: operations)
        #expect(fixture.deletes.all.isEmpty, "nothing is deleted under the service that started again: \(fixture.deletes.all)")
        #expect(status(report, ProviderUninstall.stillRunningStep) == .failed, "\(report.steps)")
    }

    @Test("m2, m3, n1: the lock and the pid file are read three ways, and only a cluster service is anyone's")
    func lockAndPidFileAreReadCarefully() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try installBoth(fixture)
        let paths = ProviderUninstallPaths(home: fixture.home, environment: .dev,
                                           commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
        let lock = fixture.outside.appendingPathComponent("cluster-setup/service.lock")
        let pidFile = fixture.outside.appendingPathComponent("cluster-setup/service.pid")
        func read(isService: Bool = true) -> ProviderUninstall.RunningClusterService? {
            ProviderUninstall.runningClusterService(lock: lock, pidFile: pidFile, paths: paths, isClusterService: { _ in isService })
        }
        #expect(read() == nil, "no lock file: no service")
        try fixture.write(lock)
        #expect(read() == nil, "a lock nobody holds: no service")
        // m3: a lock that can't be opened is not "no service".
        chmod(lock.path, 0)
        #expect(read()?.owner == .unknown && read()?.described == ProviderUninstall.unreadableLockNote)
        chmod(lock.path, 0o600)
        // Held, as a running service holds it (here through another open file of this test).
        let holder = open(lock.path, O_RDONLY)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        // n1: no readable pid, and no claim about whose it is.
        #expect(read()?.described == "a cluster service is running, and its pid can't be read")
        // m2: a pid that is not a cluster service (a stale pid file) is nobody's.
        try Data("\(getpid())\n".utf8).write(to: pidFile)
        let stale = read(isService: false)
        #expect(stale?.owner == .unknown && stale?.isThisCLI == false)
        #expect(stale?.described == "the cluster service lock is held, but pid \(getpid()) from its pid file is not a cluster service")
        let elsewhere = read(isService: true)
        #expect(elsewhere?.owner == .unknown && elsewhere?.isThisCLI == true, "this CLI's service from outside both apps")
    }

    @Test("m4: with no other install, the dry run says what `cluster stop --service` does to the service running here")
    func unsharedDryRunSaysWhatTheStopDoes() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let cli = fixture.paths.commandLink.lastPathComponent
        func step2(_ running: ProviderUninstall.RunningClusterService) -> String {
            let plan = ProviderUninstall.Plan(cli: cli, runningClusterService: running, services: [],
                                              items: ProviderUninstall.inventory(fixture.paths), pairing: nil)
            return ProviderUninstall.dryRun(plan, mode: .everything)[2]
        }
        let prefix = "  2. Stop this Mac's cluster part and remove its service, as `\(cli) cluster stop --service`: "
        #expect(step2(.init(pid: 5, executable: nil, owner: .thisInstall, isThisCLI: true))
            == prefix + "this install's cluster service is running (pid 5); this stops it")
        #expect(step2(.init(pid: 6, executable: "/elsewhere/\(cli)", owner: .unknown, isThisCLI: true))
            == prefix + "a `\(cli) cluster service` from outside this install's app is running (pid 6); this stops it too")
        #expect(step2(.init(pid: 7, executable: "/elsewhere/tool", owner: .unknown))
            == prefix + "a cluster service from outside this install's app, under another name, is running (pid 7); "
                + "this does not stop it, and nothing is deleted while it runs")
        #expect(step2(.init(pid: 0, executable: nil, owner: .unknown, note: ProviderUninstall.unreadableLockNote))
            == prefix + ProviderUninstall.unreadableLockNote + "; this does not stop it, and nothing is deleted while it runs")
    }

    @Test("a disk mounted at a folder is told from one that is not")
    func mountPointsAreDetected() throws {
        // devfs is mounted at /dev; /usr is on the same volume as /.
        #expect(ProviderUninstall.isMountPoint(URL(fileURLWithPath: "/dev")))
        #expect(!ProviderUninstall.isMountPoint(URL(fileURLWithPath: "/usr")))
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        #expect(!ProviderUninstall.isMountPoint(fixture.paths.cacheDirectory))
    }

    @Test("(d) a model cache that is itself a link, or shared with another install, is kept")
    func sharedOrLinkedModelsAreKept() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".darkbloom-staging"), withIntermediateDirectories: true)
        let shared = ProviderUninstallPaths(home: fixture.home, environment: .dev, commandLinkDirectory: fixture.paths.commandLink.deletingLastPathComponent())
        let items = ProviderUninstall.inventory(shared)
        #expect(items.filter { $0.label.hasPrefix("Model ") || $0.label == "Cluster model store" }.allSatisfy { $0.verdict == .keep })
        #expect(!items.contains { $0.label == "Model download locks" })

        let hub = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        let moved = fixture.outside.appendingPathComponent("volume-hub")
        try FileManager.default.moveItem(at: hub, to: moved)
        try fixture.link(hub, to: moved.path)
        let linked = ProviderUninstall.inventory(fixture.paths)
        #expect(linked.first { $0.label == "Models" }?.verdict == .keep)
        #expect(!linked.contains { $0.label.hasPrefix("Model ") && $0.verdict == .remove })
    }

    @Test("(e) without a terminal and without a mode, it refuses with one usage line")
    func invocationNeedsAModeWithoutATerminal() {
        let usage = ProviderUninstall.usage(cli: "darkbloom")
        #expect(usage == "Usage: darkbloom uninstall --everything|--keep-models [--yes] [--dry-run [--json]] (no terminal to ask which)")
        #expect(ProviderUninstall.invocation(everything: false, keepModels: false, yes: false, dryRun: false,
                                             interactive: false, cli: "darkbloom") == .refuse(usage))
        #expect(ProviderUninstall.invocation(everything: true, keepModels: false, yes: false, dryRun: false,
                                             interactive: false, cli: "darkbloom") == .refuse(usage), "no one to confirm")
        #expect(ProviderUninstall.invocation(everything: false, keepModels: false, yes: false, dryRun: false, interactive: true) == .ask)
        #expect(ProviderUninstall.invocation(everything: true, keepModels: false, yes: false, dryRun: false, interactive: true)
                == .run(.everything, confirm: true))
        #expect(ProviderUninstall.invocation(everything: false, keepModels: true, yes: true, dryRun: false, interactive: false)
                == .run(.keepModels, confirm: false))
        #expect(ProviderUninstall.invocation(everything: false, keepModels: false, yes: false, dryRun: true, interactive: false)
                == .dryRun([.everything, .keepModels]))
        // Run as root (`sudo`), it would read root's home and miss this person's Darkbloom: refused, dry run too.
        let root = ProviderUninstall.rootRefusal(cli: "darkbloom")
        #expect(root == "Run `darkbloom uninstall` as yourself, not with sudo: it removes your own Darkbloom, "
            + "and asks for your password when a step needs it.")
        for (everything, keepModels, yes, dryRun) in [(false, false, false, false), (true, false, true, false),
                                                      (false, true, true, false), (false, false, false, true)] {
            #expect(ProviderUninstall.invocation(everything: everything, keepModels: keepModels, yes: yes, dryRun: dryRun,
                                                 interactive: true, userID: 0, cli: "darkbloom") == .refuse(root))
        }
        #expect(ProviderUninstall.invocation(everything: true, keepModels: false, yes: true, dryRun: false, interactive: false,
                                             userID: 501) == .run(.everything, confirm: false))
        // After 1 on the screen, one more question; anything but y or yes keeps everything.
        for answer in ["y", "yes", " Y "] { #expect(ProviderUninstall.confirmed(answer)) }
        for answer in [nil, "", "n", "no", "1"] as [String?] { #expect(!ProviderUninstall.confirmed(answer)) }
        // The screen's keys: 1 or 2 choose, Esc cancels, an arrow key's sequence or another key waits.
        #expect(ProviderUninstall.key(Array("1".utf8)) == .choose(.everything))
        #expect(ProviderUninstall.key(Array("2".utf8)) == .choose(.keepModels))
        for cancel in [[0x1B], [], Array("q".utf8), [0x03], [0x04]] as [[UInt8]] { #expect(ProviderUninstall.key(cancel) == .cancel) }
        for ignored in [[0x1B, 0x5B, 0x41], Array("3".utf8), Array("\n".utf8)] as [[UInt8]] { #expect(ProviderUninstall.key(ignored) == nil) }
    }

    @Test("(f) on a paired leader and member, the last line names the other Mac and what to run there")
    func pairedMacsEndWithTheOtherMac() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let leader = fixture.pairing
        var member = leader
        member.role = .member
        member.otherMacName = "M4 Max, 128 GB"
        var unnamed = leader
        unnamed.otherMacName = nil
        unnamed.role = nil
        let cases: [(ProviderUninstallPairing, String)] = [
            (leader, "The other Mac (M3 Ultra, 512 GB) followed this one: run `darkbloom uninstall` there too, "
                + "or `darkbloom cluster` on it to pair it with another Mac."),
            (member, "The other Mac (M4 Max, 128 GB) led this pair: run `darkbloom uninstall` there too, "
                + "or `darkbloom cluster` on it to pair it with another Mac."),
            (unnamed, "The other Mac is paired with this one: run `darkbloom uninstall` there too, "
                + "or `darkbloom cluster` on it to pair it with another Mac."),
        ]
        for mode in ProviderUninstall.Mode.allCases {
            let report = ProviderUninstall.Report(mode: mode, steps: [], availableBefore: nil, availableAfter: nil)
            for (pairing, line) in cases {
                #expect(ProviderUninstall.summary(report, plan: fixture.plan(pairing: pairing)).last == line, "\(mode)")
            }
            let alone = ProviderUninstall.summary(report, plan: fixture.plan(pairing: nil))
            #expect(!alone.contains { $0.hasPrefix("The other Mac") })
        }
        #expect(ProviderUninstallPairing.read(home: fixture.home) == nil, "an unreadable or absent pairing is not a pair")
    }

    @Test("(f) the other Mac's name and this Mac's role come from the saved setup, as `darkbloom cluster` shows them")
    func pairedRoleComesFromTheSavedSetup() throws {
        let home = try NativePairMemberFixture.privateRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClusterSetupStore(paths: .init(paths: try ClusterUserPaths(homeDirectory: home)))
        let pin = Fixture.pin
        let peers = [ProviderUninstallPairing.Peer(pin: pin, name: "Apple M3 Ultra, 512 GB")]
        #expect(ProviderUninstallPairing.describing(peers: peers, latest: peers[0], home: home, local: nil)
                == .init(peers: peers, otherMacName: "Apple M3 Ultra, 512 GB", role: nil), "no saved setup: the pairing's name")
        for (role, relation) in [("leader", "followed this one"), ("member", "led this pair")] {
            _ = try store.updateRecord {
                $0.leadership = ClusterOnboardingLeadership(role: role, leaderPin: String(repeating: "a", count: 64), peerPin: pin,
                                                            peerName: "Apple M4 Max, 128 GB", since: "2026-11-03T00:00:00Z")
            }
            let pairing = ProviderUninstallPairing.describing(peers: peers, latest: peers[0], home: home, local: nil)
            #expect(pairing.role == ClusterOnboardingRole(rawValue: role))
            #expect(ProviderUninstall.otherMacLine(pairing, cli: "darkbloom") == "The other Mac (Apple M4 Max, 128 GB) \(relation): "
                + "run `darkbloom uninstall` there too, or `darkbloom cluster` on it to pair it with another Mac.")
        }
        _ = try store.updateRecord { $0.leadership?.peerPin = String(repeating: "c", count: 64) }
        #expect(ProviderUninstallPairing.describing(peers: peers, latest: peers[0], home: home, local: nil).role == nil,
                "a setup saved for another pairing says nothing about this one")
    }

    @Test("the account token is revoked once, best effort: an unconfirmed revocation is reported and blocks nothing")
    func tokenRevocationIsBestEffort() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.keepModels, items: plan.items, pairing: fixture.pairing,
                                       operations: fixture.operations(tokenUnconfirmed: true))
        #expect(fixture.calls.count("revoke token") == 1)
        #expect(report.steps.first { $0.name == "Revoke this Mac's account token" }
                == .init(name: "Revoke this Mac's account token", status: .skipped,
                         detail: "the coordinator did not confirm it (offline, or the token's issuer is unknown)"))
        #expect(!report.failed)
        #expect(!fixture.exists(fixture.paths.installDirectory), "the token goes with ~/.darkbloom all the same")
        #expect(fixture.calls.count("forget") == 1 && fixture.calls.count("link remove") == 1)

        // A provider that did not stop still holds the token: it is not revoked under it.
        let second = try Fixture.make()
        defer { second.remove() }
        let draining = await second.run(.everything, operations: second.operations(drainFails: true))
        #expect(second.calls.count("revoke token") == 0)
        #expect(status(draining, "Revoke this Mac's account token") == .skipped)
    }

    @Test("(g) one failing step: the others run, and the summary says which failed and why")
    func failedStepIsReportedAndTheRestRun() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.everything, items: plan.items, pairing: fixture.pairing,
                                       operations: fixture.operations(linkFails: true))

        #expect(report.failed)
        #expect(report.steps.filter { $0.status == .failed }.map(\.name) == ["Undo the cable port setup"])
        #expect(!fixture.exists(fixture.paths.configDirectory) && !fixture.exists(fixture.paths.clusterModelStore),
                "deleting settings and models does not need the cable")
        // The app, the cable records and an administrator's script are in ~/.darkbloom: it stays, with the command
        // link, so `darkbloom uninstall --everything` can run again and undo the cable port setup.
        #expect(fixture.exists(fixture.paths.installDirectory.appendingPathComponent("cluster-pairing/pairings.json")))
        #expect(fixture.exists(fixture.paths.commandLink))
        let retry = "kept, so the uninstall can run again and undo the cable port setup (it holds the app and the cable records)"
        let kept = report.steps.filter { $0.status == .skipped && $0.detail == retry }.map(\.name)
        #expect(kept == ["Delete The `\(fixture.paths.commandLink.lastPathComponent)` command link",
                         "Delete " + ProviderUninstall.installFolderLabel])
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("everything-summary-link-declined", summary, fixture)
        #expect(summary.contains("  failed   Undo the cable port setup: the macOS prompt was declined; nothing was changed "
            + ProviderUninstall.cableLeftNote()), "\(summary)")
        // R5-2: the pairing was forgotten first (it tells the other Mac over the cable); the failed cable step says so,
        // and the one command that finishes the rest.
        let cable = report.steps.first { $0.name == ProviderUninstall.cableStep }
        #expect(cable?.detail == "the macOS prompt was declined; nothing was changed " + ProviderUninstall.cableLeftNote(),
                "\(String(describing: cable?.detail))")
        #expect(ProviderUninstall.cableLeftNote(cli: "darkbloom-dev") == "The pairing is already forgotten; only the cable port setup is left. "
            + "To finish, run `darkbloom-dev uninstall` again (it kept the app for that).")
        #expect(summary.contains { $0.hasPrefix("  done     Delete Settings: ") })

        // A cluster service that did not stop: every other service is still removed, and no file is deleted under it.
        let second = try Fixture.make()
        defer { second.remove() }
        let secondPlan = second.plan(pairing: second.pairing)
        let stuck = await second.run(.keepModels, items: secondPlan.items, pairing: second.pairing,
                                     operations: second.operations(clusterFails: true))
        #expect(stuck.steps.filter { $0.status == .failed }.map(\.name) == ["Stop this Mac's cluster part and remove its service"])
        #expect(status(stuck, "Remove the provider service") == .done && status(stuck, "Remove the watchdog service") == .done)
        #expect(second.calls.count("forget") == 1 && second.calls.count("link remove") == 1)
        #expect(stuck.steps.filter { $0.name.hasPrefix("Delete ") }.allSatisfy {
            $0.status == .skipped && $0.detail == ProviderUninstall.servicesRunningReason })
        #expect(second.exists(second.paths.installDirectory))
        let stuckSummary = ProviderUninstall.summary(stuck, plan: secondPlan)
        transcript("keep-models-summary-cluster-stuck", stuckSummary, second)
        #expect(stuckSummary.first == "Darkbloom is not fully removed from this Mac (see the failed step).")
        #expect(!stuckSummary.contains { $0.hasPrefix("Space freed") }, "nothing was deleted, so no space is claimed")

        // A provider that did not drain keeps its agents, as `stop --uninstall` leaves them.
        let third = try Fixture.make()
        defer { third.remove() }
        let draining = await third.run(.keepModels, operations: third.operations(drainFails: true))
        #expect(status(draining, "Stop serving on this Mac") == .failed)
        #expect(status(draining, "Remove the provider service") == .skipped)
        #expect(third.exists(third.agents.appendingPathComponent("\(LaunchAgent.label).plist")))
        #expect(!third.launchd.bootedOut.contains(LaunchAgent.label))
    }

    @Test("every step is idempotent: a second run finds nothing left and fails nothing")
    func secondRunFindsNothing() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = await fixture.run(.everything, pairing: fixture.pairing)
        let again = await fixture.run(.everything)
        #expect(!again.failed, "\(again.steps)")
        #expect(again.steps.filter { $0.name.hasPrefix("Remove the ") }.allSatisfy { $0.status == .skipped && $0.detail == "not installed" })
        #expect(!again.steps.contains { $0.name.hasPrefix("Delete ") && $0.status != .skipped })
        #expect(status(again, "Forget this Mac's pairing") == .skipped)
    }
}
