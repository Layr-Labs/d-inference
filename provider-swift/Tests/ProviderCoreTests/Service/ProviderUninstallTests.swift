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
    var failBootout: Set<String> = []

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
                if failBootout.contains(label) {
                    return .init(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error\n")
                }
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
    var callCount: Int { lock.withLock { calls.count } }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

private struct Fixture {
    static let pin = String(repeating: "ab", count: 32)
    static let clusterLabel = ClusterServiceAgentPlan.labelPrefix + "0123456789ab"

    let root: URL
    let home: URL
    let outside: URL
    let paths: ProviderUninstallPaths
    let launchd: FakeLaunchd
    let calls = Calls()

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
                     ".cache/huggingface/hub/models--org--ours/snapshots/rev1/.darkbloom-manifest.json",
                     ".cache/huggingface/hub/models--org--ours/snapshots/rev1/model.safetensors",
                     ".cache/huggingface/hub/models--org--partial/snapshots/.local-staging-v2__org__partial/a.part",
                     ".cache/huggingface/hub/models--org--other/snapshots/rev1/model.safetensors",
                     ".cache/huggingface/hub/.artifact-writer-locks/models--org--ours",
                     ".cache/huggingface/darkbloom-cluster-models/org--ours/model.safetensors",
                     "Library/LaunchAgents/\(LaunchAgent.label).plist", "Library/LaunchAgents/\(WatchdogAgent.label).plist",
                     "Library/LaunchAgents/io.darkbloom.desktop-api.plist", "Library/LaunchAgents/\(clusterLabel).plist"] {
            try fixture.write(home.appendingPathComponent(file))
        }
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

    func operations(drainFails: Bool = false, clusterFails: Bool = false, linkFails: Bool = false) -> ProviderUninstall.Operations {
        let calls = calls, desktop = desktopPlist
        let free = Calls()
        return .init(
            stopServing: {
                calls.add("drain")
                if drainFails { throw ProviderUninstall.StepFailure("1 accepted request still running after 600 s") }
                return .done()
            },
            stopClusterPart: {
                calls.add("cluster stop")
                if clusterFails { throw ProviderUninstall.StepFailure("the other Mac did not acknowledge the stop") }
                return try ClusterServiceAgent.uninstall().isEmpty ? .skipped("no cluster service on this Mac") : .done()
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
            forget: { calls.add("forget \($0)") },
            removeCableSetup: {
                calls.add("link remove")
                if linkFails { throw ProviderUninstall.StepFailure("the macOS prompt was declined; nothing was changed") }
                return .done()
            },
            availableBytes: {
                free.add("measured")
                return free.count("measured") == 1 ? 1_000_000_000 : 1_250_000_000
            })
    }

    /// Runs with the fake home and the fake launchctl.
    func run(_ mode: ProviderUninstall.Mode, items: [ProviderUninstallItem]? = nil, pairing: ProviderUninstallPairing? = nil,
             operations: ProviderUninstall.Operations? = nil) async -> ProviderUninstall.Report {
        await LaunchctlControl.$homeDirectoryForTesting.withValue(home) {
            await LaunchctlControl.$runnerForTesting.withValue({ try launchd.run($0) }) {
                await ProviderUninstall.run(mode, items: items ?? ProviderUninstall.inventory(paths), pairing: pairing,
                                            operations: operations ?? self.operations())
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

@Suite("darkbloom uninstall")
struct ProviderUninstallTests {
    @Test("(a) keep: every service is removed and every file stays")
    func keepRemovesServicesAndKeepsData() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let before = fixture.tree(fixture.root, excluding: "home/Library/LaunchAgents")
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.keepData, items: plan.items, pairing: fixture.pairing)

        #expect(!report.failed, "\(report.steps)")
        #expect(fixture.tree(fixture.agents).isEmpty, "provider, watchdog, desktop API and cluster agents are gone")
        #expect(Set(fixture.launchd.bootedOut) == [LaunchAgent.label, WatchdogAgent.label, Fixture.clusterLabel])
        #expect(fixture.tree(fixture.root, excluding: "home/Library/LaunchAgents") == before, "no file was deleted")
        #expect(fixture.calls.all == ["drain", "cluster stop", "lease released"], "no unpairing and no cable change")
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("keep-summary-leader", summary, fixture)
        #expect(summary.contains("To come back: install Darkbloom again, then run `darkbloom start` or `darkbloom cluster`."))
        #expect(summary.contains(ProviderUninstall.keychainLine))
    }

    @Test("(b) everything: data, models, the app and the command link go; forget and link remove run once each")
    func everythingRemovesDarkbloomData() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let hub = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        let plan = fixture.plan(pairing: fixture.pairing)
        let report = await fixture.run(.everything, items: plan.items, pairing: fixture.pairing)

        #expect(!report.failed, "\(report.steps)")
        for gone in [fixture.paths.installDirectory, fixture.paths.configDirectory, fixture.paths.cacheDirectory,
                     hub.appendingPathComponent("models--org--ours"), hub.appendingPathComponent("models--org--partial"),
                     hub.appendingPathComponent(".artifact-writer-locks"), fixture.paths.clusterModelStore,
                     fixture.paths.commandLink] {
            #expect(!fixture.exists(gone), "\(gone.path) is deleted")
        }
        #expect(fixture.exists(hub.appendingPathComponent("models--org--other/snapshots/rev1/model.safetensors")),
                "another tool's model in the shared cache stays")
        #expect(fixture.exists(fixture.savedModels.appendingPathComponent("models--org--big/snapshots/rev1/.darkbloom-manifest.json")),
                "models in the folder the person chose stay")
        #expect(fixture.calls.count("forget \(Fixture.pin)") == 1)
        #expect(fixture.calls.count("link remove") == 1)
        #expect(fixture.calls.all.firstIndex(of: "forget \(Fixture.pin)")! < fixture.calls.all.firstIndex(of: "link remove")!,
                "the other Mac is told over the cable before the cable's setup is undone")
        #expect(report.steps.last?.name == "Delete Darkbloom folder: the app, logs, pairing and cluster setup",
                "the folder with the running app goes last")
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("everything-summary-leader", summary, fixture)
        #expect(summary.contains { $0.hasPrefix("Space freed: 250 MB (this disk had 1 GB free, now 1.25 GB") })
        #expect(summary.contains { $0.hasPrefix("Kept: Models in the folder you chose") && $0.contains(fixture.savedModels.path) })
        #expect(summary.contains(ProviderUninstall.keychainLine))
    }

    @Test("(c) dry run: lists every action and path with sizes, and changes nothing")
    func dryRunChangesNothing() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let before = fixture.tree(fixture.root)
        let plan = fixture.plan(pairing: fixture.pairing)
        let lines = ProviderUninstall.dryRun(plan, mode: .everything)
        let text = lines.joined(separator: "\n")
        transcript("screen", ProviderUninstall.screen(plan), fixture)
        transcript("dry-run-everything", lines, fixture)
        transcript("dry-run-keep-data", ProviderUninstall.dryRun(plan, mode: .keepData), fixture)

        #expect(fixture.tree(fixture.root) == before)
        #expect(fixture.launchd.callCount == 0, "nothing asked launchd")
        #expect(fixture.calls.all.isEmpty)
        for item in plan.items where item.verdict == .remove {
            #expect(text.contains("Delete \(ProviderUninstall.row(item))"))
            #expect(item.bytes > 0 || item.path == fixture.paths.commandLink.path, "\(item.label) is measured")
        }
        #expect(plan.items.first { $0.label == "Model org/ours" }.map { $0.bytes >= 16384 } == true, "sizes are measured")
        for action in ["Stop serving on this Mac",
                       "Stop this Mac's cluster part and remove its service, as `darkbloom cluster stop`: "
                        + "\(fixture.agents.path)/\(Fixture.clusterLabel).plist",
                       "Remove the provider service: \(fixture.agents.path)/\(LaunchAgent.label).plist",
                       "Remove the watchdog service: \(fixture.agents.path)/\(WatchdogAgent.label).plist",
                       "Remove the desktop API service: \(fixture.desktopPlist.path)",
                       "Forget the pairing with M3 Ultra, 512 GB", "Undo the cable port setup"] {
            #expect(text.contains(action), "\(action)")
        }
        #expect(text.contains("Keeps Models in the folder you chose"))
        let keep = ProviderUninstall.dryRun(plan, mode: .keepData).joined(separator: "\n")
        #expect(!keep.contains("Delete ") && !keep.contains("Forget") && keep.contains("Keeps every file"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(ProviderUninstall.dryRunDocument(plan, modes: ProviderUninstall.Mode.allCases))
        transcript("dry-run-json", [String(decoding: json, as: UTF8.self)], fixture)
        let document = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(document["schema"] as? String == "darkbloom_uninstall_plan_v1")
        #expect((document["modes"] as? [[String: Any]])?.count == 2)
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
        #expect(report.steps.filter { $0.detail?.hasPrefix("refused: ") == true }.count == 3)
        #expect(status(report, "Delete Settings") == .skipped)
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
        #expect(ProviderUninstall.invocation(keepData: false, everything: false, yes: false, dryRun: false,
                                             interactive: false, cli: "darkbloom") == .refuse(usage))
        #expect(ProviderUninstall.invocation(keepData: false, everything: true, yes: false, dryRun: false,
                                             interactive: false, cli: "darkbloom") == .refuse(usage), "no one to confirm")
        #expect(!usage.contains("\n"))
        #expect(ProviderUninstall.invocation(keepData: false, everything: false, yes: false, dryRun: false, interactive: true) == .ask)
        #expect(ProviderUninstall.invocation(keepData: false, everything: true, yes: false, dryRun: false, interactive: true)
                == .run(.everything, confirm: true))
        #expect(ProviderUninstall.invocation(keepData: true, everything: false, yes: true, dryRun: false, interactive: false)
                == .run(.keepData, confirm: false))
        #expect(ProviderUninstall.invocation(keepData: false, everything: false, yes: false, dryRun: true, interactive: false)
                == .dryRun([.keepData, .everything]))
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
            let report = ProviderUninstall.Report(mode: mode, steps: [], items: [], availableBefore: nil, availableAfter: nil)
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
                         "Delete Darkbloom folder: the app, logs, pairing and cluster setup"])
        let summary = ProviderUninstall.summary(report, plan: plan)
        transcript("everything-summary-link-declined", summary, fixture)
        #expect(summary.contains("  failed   Undo the cable port setup: the macOS prompt was declined; nothing was changed"))
        #expect(summary.contains { $0.hasPrefix("  done     Delete Settings: ") })

        // A cluster service that did not stop: every other service is still removed, and no file is deleted under it.
        let second = try Fixture.make()
        defer { second.remove() }
        let secondPlan = second.plan(pairing: second.pairing)
        let stuck = await second.run(.everything, items: secondPlan.items, pairing: second.pairing,
                                     operations: second.operations(clusterFails: true))
        #expect(stuck.steps.filter { $0.status == .failed }.map(\.name) == ["Stop this Mac's cluster part and remove its service"])
        #expect(status(stuck, "Remove the provider service") == .done && status(stuck, "Remove the watchdog service") == .done)
        #expect(second.calls.count("forget") == 1 && second.calls.count("link remove") == 1)
        #expect(stuck.steps.filter { $0.name.hasPrefix("Delete ") }.allSatisfy {
            $0.status == .skipped && $0.detail == ProviderUninstall.servicesRunningReason })
        #expect(second.exists(second.paths.installDirectory))
        let stuckSummary = ProviderUninstall.summary(stuck, plan: secondPlan)
        transcript("everything-summary-cluster-stuck", stuckSummary, second)
        #expect(stuckSummary.first == "Darkbloom is not fully removed from this Mac (see the failed step).")
        #expect(!stuckSummary.contains { $0.hasPrefix("Space freed") }, "nothing was deleted, so no space is claimed")

        // A provider that did not drain keeps its agents, as `stop --uninstall` leaves them.
        let third = try Fixture.make()
        defer { third.remove() }
        let draining = await third.run(.keepData, operations: third.operations(drainFails: true))
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
