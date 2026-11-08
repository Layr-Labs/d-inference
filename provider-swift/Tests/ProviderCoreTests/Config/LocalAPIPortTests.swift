import Foundation
import Testing
@testable import ProviderCore

/// This Mac's one local API port (`LocalAPIPort`): saved in `[local] port`, and then kept by every start; a saved or
/// named port always wins. With none saved, the port this Mac's local API already uses is kept (8000 on a Mac updated
/// from 0.10.10), and only a Mac with no local API at all chooses one (the first free from 8001, never 8000 or
/// 47420–47423). `thisMac` is the shared function for a local API that starts at once (the desktop app's local mode, a
/// pair's API). Nothing here binds a port or reads this Mac's LaunchAgent: the closures stand in for them.
@Suite("This Mac's local API port")
struct LocalAPIPortTests {
    private static let fallback = ProviderConfig(provider: ProviderSettings(name: "one-port"))
    /// The first port a choice takes on this build: 8001 under production's identity (8000 is never chosen).
    private static let first: UInt16 = LocalAPIPort.firstTried == 8000 ? 8001 : LocalAPIPort.firstTried

    private func configFile(_ toml: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-api-port-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("provider.toml")
        if let toml { try toml.write(to: path, atomically: true, encoding: .utf8) }
        return path
    }

    @Test("without a saved port: the first free from 8001, saved; 8000 and the pair ports are never probed")
    func choosesOnceAndSaves() throws {
        var probed: [UInt16] = []
        let choice = try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, installedPort: { nil },
                                             isFree: { probed.append($0); return true })
        #expect(choice == LocalAPIPort.Choice(port: Self.first, saves: true,
                                              note: LocalAPIPort.note(chosen: Self.first, start: LocalAPIPort.firstTried)))
        #expect(!probed.contains(8000) && !probed.contains { (47_420...47_423).contains($0) })
        #expect(LocalAPIPort.firstCandidate == Self.first, "the port `--port`'s help names")
        // Another program holds it: the next one. This install's own running API holds it: kept.
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, installedPort: { nil },
                                        isFree: { $0 != Self.first }).port == Self.first + 1)
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { Self.first }, installedPort: { nil },
                                        isFree: { _ in false }).port == Self.first)
        #expect(throws: LocalAPIPortError(start: LocalAPIPort.firstTried)) {
            try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, installedPort: { nil },
                                    isFree: { _ in false })
        }
    }

    @Test("a saved port wins, even 8000 or one another program holds, and nothing is probed")
    func savedPortWins() throws {
        for saved: UInt16 in [8005, 8000] {
            let choice = try LocalAPIPort.choose(named: nil, saved: saved, ownLivePort: {
                Issue.record("asked for the live port"); return nil
            }, installedPort: {
                Issue.record("asked for the installed job's port"); return nil
            }, isFree: { _ in Issue.record("probed"); return false })
            #expect(choice == LocalAPIPort.Choice(port: saved, saves: false, note: nil))
        }
    }

    @Test("a named port wins and is saved, and the line names the port it replaces")
    func namedPortWinsAndIsSaved() throws {
        let noProbe: (UInt16) -> Bool = { _ in Issue.record("probed"); return false }
        #expect(try LocalAPIPort.choose(named: 8007, saved: nil, ownLivePort: { nil }, installedPort: { nil },
                                        isFree: noProbe)
            == LocalAPIPort.Choice(port: 8007, saves: true, note: "Local API port: 8007 (saved)."))
        #expect(try LocalAPIPort.choose(named: 8007, saved: 8005, ownLivePort: { nil }, installedPort: { nil },
                                        isFree: noProbe)
            == LocalAPIPort.Choice(port: 8007, saves: true, note: "Local API port: 8007 (saved, instead of 8005: tools "
                + "set up for 8005 need `darkbloom start --opencode` or `--hermes` again)."))
        #expect(try LocalAPIPort.choose(named: 8005, saved: 8005, ownLivePort: { nil }, installedPort: { nil },
                                        isFree: noProbe)
            == LocalAPIPort.Choice(port: 8005, saves: false, note: nil))
    }

    @Test("thisMac: the saved port, else a new one saved at once; the rest of the file is kept")
    func thisMacSavesOnce() throws {
        // No file yet: chosen, and the file is written with it.
        let absent = try configFile(nil)
        let made = try LocalAPIPort.thisMac(configPath: absent, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                            installedPort: { nil }, isFree: { _ in true })
        #expect(made.port == Self.first && made.saves)
        #expect(try ConfigManager.load(from: absent).local?.port == Self.first)

        // A file without [local] port: chosen and saved, nothing else changes.
        let file = try configFile("[provider]\nname = \"kept\"\n\n[local]\nmode = \"both\"\n")
        let chosen = try LocalAPIPort.thisMac(configPath: file, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                              installedPort: { nil }, isFree: { $0 != Self.first })
        #expect(chosen.port == Self.first + 1 && chosen.note == LocalAPIPort.note(chosen: Self.first + 1,
                                                                                  start: LocalAPIPort.firstTried))
        let saved = try ConfigManager.load(from: file)
        #expect(saved.local == LocalSettings(mode: .both, port: Self.first + 1) && saved.provider.name == "kept")

        // Saved: the same port, nothing probed or written.
        let before = try Data(contentsOf: file)
        let again = try LocalAPIPort.thisMac(configPath: file, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                             installedPort: { nil }, isFree: { _ in Issue.record("probed"); return true })
        #expect(again == LocalAPIPort.Choice(port: Self.first + 1, saves: false, note: nil))
        #expect(try Data(contentsOf: file) == before)

        // None free: said plainly, nothing written.
        let full = try configFile("[provider]\nname = \"full\"\n")
        let untouched = try Data(contentsOf: full)
        #expect(throws: LocalAPIPortError.self) {
            try LocalAPIPort.thisMac(configPath: full, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                     installedPort: { nil }, isFree: { _ in false })
        }
        #expect(try Data(contentsOf: full) == untouched)
    }

    @Test("the port a line suggests next is free, never the one in use, 8000 or a pair port")
    func nextFreeForTheLine() {
        #expect(LocalAPIPort.nextFree(besides: Self.first, isFree: { _ in true }) == Self.first + 1)
        #expect(LocalAPIPort.nextFree(besides: 8005, isFree: { _ in true }) == Self.first)
        #expect(LocalAPIPort.nextFree(besides: Self.first, isFree: { _ in false }) == nil)
        #expect(LocalAPIPortError(start: 8000).description == "No free port for this Mac's API from 8000 to 8020 (8000 "
            + "and 47420–47423 are never chosen). Free one, or name one with --port <n>.")
    }

    @Test("no saved port: the one this Mac's local API already uses is kept and saved, even 8000; a Mac with none chooses")
    func keepsThePortItsLocalAPIAlreadyUses() throws {
        let noProbe: (UInt16) -> Bool = { _ in Issue.record("probed"); return true }
        let kept = LocalAPIPort.Choice(port: 8000, saves: true, note: "Local API port: 8000 (saved; this Mac's local API "
            + "already uses it).")
        // A Mac updated from 0.10.10 serves its local API on 8000: running, or installed in its LaunchAgent while
        // stopped. The running API's port comes first.
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { 8000 }, installedPort: {
            Issue.record("asked for the installed job's port beside a running API"); return 8003
        }, isFree: noProbe) == kept)
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, installedPort: { 8000 },
                                        isFree: noProbe) == kept)
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { 8005 }, installedPort: { nil },
                                        isFree: noProbe).port == 8005)
        // A Mac with no local API at all: the first free from 8001.
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, installedPort: { nil },
                                        isFree: { _ in true }).port == Self.first)
        // A saved or a named port still wins over the one in use.
        #expect(try LocalAPIPort.choose(named: nil, saved: 8001, ownLivePort: { 8000 }, installedPort: { 8000 },
                                        isFree: noProbe) == LocalAPIPort.Choice(port: 8001, saves: false, note: nil))
        #expect(try LocalAPIPort.choose(named: 8007, saved: nil, ownLivePort: { 8000 }, installedPort: { 8000 },
                                        isFree: noProbe).port == 8007)
    }

    @Test("thisMac on a Mac updated from 0.10.10 keeps its API's port and saves it")
    func thisMacKeepsAnUpdatedMacsPort() throws {
        let file = try configFile("[provider]\nname = \"updated\"\n")
        let kept = try LocalAPIPort.thisMac(configPath: file, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                            installedPort: { 8000 }, isFree: { _ in Issue.record("probed"); return true })
        #expect(kept == LocalAPIPort.Choice(port: 8000, saves: true, note: LocalAPIPort.note(kept: 8000)))
        let saved = try ConfigManager.load(from: file)
        #expect(saved.local?.port == 8000 && saved.provider.name == "updated")
    }

    @Test("a port another start saved meanwhile stands, and nothing is written over it")
    func aPortSavedMeanwhileStands() throws {
        let file = try configFile("[provider]\nname = \"race\"\n\n[local]\nport = 8009\n")
        let before = try Data(contentsOf: file)
        let choice = LocalAPIPort.Choice(port: Self.first, saves: true,
                                         note: LocalAPIPort.note(chosen: Self.first, start: LocalAPIPort.firstTried))
        #expect(try LocalAPIPort.save(choice, configPath: file, fallbackConfig: Self.fallback)
            == LocalAPIPort.Choice(port: 8009, saves: false, note: nil))
        #expect(try ConfigManager.load(from: file).local?.port == 8009 && Data(contentsOf: file) == before)
    }

    @Test("the installed job's local API port: its --port, else an older app job's default; none for a network or cluster job")
    func installedJobsPort() throws {
        let binary = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
        let coordinator = "wss://coordinator.invalid/ws/provider"
        // 0.10.10's Both job (the app's onboarding, "Alongside the network", `--local-endpoint`).
        let both = LaunchAgent.serviceProgramArguments(
            binaryPath: binary, coordinatorURL: coordinator, models: ["fixture/model"], configPath: nil,
            localEndpoint: LaunchAgent.LocalEndpointOptions(enabled: true, port: 8000, bind: "127.0.0.1", noAuth: false))
        #expect(LaunchAgent.localAPIPort(ofJob: both) == 8000)
        // The app's local job before this build: `start --local --model …`, no port.
        #expect(LaunchAgent.localAPIPort(ofJob: [binary, "start", "--local", "--model", "fixture/model"])
            == BuildEnvironment.current.defaultLocalPort)
        // This build's local job.
        #expect(LaunchAgent.localAPIPort(ofJob: LaunchAgent.localProgramArguments(
            binaryPath: binary, models: ["fixture/model"], configPath: nil, port: 8005, bind: "127.0.0.1",
            noAuth: false)) == 8005)
        // No local API: the network job, a cluster member's, the cluster's leader.
        #expect(LaunchAgent.localAPIPort(ofJob: LaunchAgent.serviceProgramArguments(
            binaryPath: binary, coordinatorURL: coordinator, models: ["fixture/model"], configPath: nil)) == nil)
        #expect(LaunchAgent.localAPIPort(ofJob: [binary, "start", "--foreground", "--cluster-member", "--local-endpoint",
                                                 "--port", "8001"]) == nil)
        #expect(LaunchAgent.localAPIPort(ofJob: [binary, "start", "--local", "--distributed"]) == nil)

        // Read from the plist on disk; none there, nothing.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-api-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("job.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture", "ProgramArguments": both],
                                           format: .xml, options: 0).write(to: plist)
        #expect(LaunchAgent.installedLocalAPIPort(at: plist) == 8000)
        #expect(LaunchAgent.installedLocalAPIPort(at: directory.appendingPathComponent("absent.plist")) == nil)
    }
}
