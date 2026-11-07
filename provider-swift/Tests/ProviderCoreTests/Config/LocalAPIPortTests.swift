import Foundation
import Testing
@testable import ProviderCore

/// This Mac's one local API port (`LocalAPIPort`): chosen once (the first free from 8001, never 8000 or 47420–47423),
/// saved in `[local] port`, and then kept by every start; a saved or named port always wins. `thisMac` is the shared
/// function for a local API that starts at once (the desktop app's local mode, a pair's API). Nothing here binds a
/// port: `isFree` stands in for the probe.
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
        let choice = try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil },
                                             isFree: { probed.append($0); return true })
        #expect(choice == LocalAPIPort.Choice(port: Self.first, saves: true,
                                              note: LocalAPIPort.note(chosen: Self.first, start: LocalAPIPort.firstTried)))
        #expect(!probed.contains(8000) && !probed.contains { (47_420...47_423).contains($0) })
        // Another program holds it: the next one. This install's own running API holds it: kept.
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil },
                                        isFree: { $0 != Self.first }).port == Self.first + 1)
        #expect(try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { Self.first },
                                        isFree: { _ in false }).port == Self.first)
        #expect(throws: LocalAPIPortError(start: LocalAPIPort.firstTried)) {
            try LocalAPIPort.choose(named: nil, saved: nil, ownLivePort: { nil }, isFree: { _ in false })
        }
    }

    @Test("a saved port wins, even 8000 or one another program holds, and nothing is probed")
    func savedPortWins() throws {
        for saved: UInt16 in [8005, 8000] {
            let choice = try LocalAPIPort.choose(named: nil, saved: saved, ownLivePort: {
                Issue.record("asked for the live port"); return nil
            }, isFree: { _ in Issue.record("probed"); return false })
            #expect(choice == LocalAPIPort.Choice(port: saved, saves: false, note: nil))
        }
    }

    @Test("a named port wins and is saved, and the line names the port it replaces")
    func namedPortWinsAndIsSaved() throws {
        let noProbe: (UInt16) -> Bool = { _ in Issue.record("probed"); return false }
        #expect(try LocalAPIPort.choose(named: 8007, saved: nil, ownLivePort: { nil }, isFree: noProbe)
            == LocalAPIPort.Choice(port: 8007, saves: true, note: "Local API port: 8007 (saved)."))
        #expect(try LocalAPIPort.choose(named: 8007, saved: 8005, ownLivePort: { nil }, isFree: noProbe)
            == LocalAPIPort.Choice(port: 8007, saves: true, note: "Local API port: 8007 (saved, instead of 8005: tools "
                + "set up for 8005 need `darkbloom start --opencode` or `--hermes` again)."))
        #expect(try LocalAPIPort.choose(named: 8005, saved: 8005, ownLivePort: { nil }, isFree: noProbe)
            == LocalAPIPort.Choice(port: 8005, saves: false, note: nil))
    }

    @Test("thisMac: the saved port, else a new one saved at once; the rest of the file is kept")
    func thisMacSavesOnce() throws {
        // No file yet: chosen, and the file is written with it.
        let absent = try configFile(nil)
        let made = try LocalAPIPort.thisMac(configPath: absent, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                            isFree: { _ in true })
        #expect(made.port == Self.first && made.saves)
        #expect(try ConfigManager.load(from: absent).local?.port == Self.first)

        // A file without [local] port: chosen and saved, nothing else changes.
        let file = try configFile("[provider]\nname = \"kept\"\n\n[local]\nmode = \"both\"\n")
        let chosen = try LocalAPIPort.thisMac(configPath: file, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                              isFree: { $0 != Self.first })
        #expect(chosen.port == Self.first + 1 && chosen.note == LocalAPIPort.note(chosen: Self.first + 1,
                                                                                  start: LocalAPIPort.firstTried))
        let saved = try ConfigManager.load(from: file)
        #expect(saved.local == LocalSettings(mode: .both, port: Self.first + 1) && saved.provider.name == "kept")

        // Saved: the same port, nothing probed or written.
        let before = try Data(contentsOf: file)
        let again = try LocalAPIPort.thisMac(configPath: file, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                             isFree: { _ in Issue.record("probed"); return true })
        #expect(again == LocalAPIPort.Choice(port: Self.first + 1, saves: false, note: nil))
        #expect(try Data(contentsOf: file) == before)

        // None free: said plainly, nothing written.
        let full = try configFile("[provider]\nname = \"full\"\n")
        let untouched = try Data(contentsOf: full)
        #expect(throws: LocalAPIPortError.self) {
            try LocalAPIPort.thisMac(configPath: full, fallbackConfig: Self.fallback, ownLivePort: { nil },
                                     isFree: { _ in false })
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
}
