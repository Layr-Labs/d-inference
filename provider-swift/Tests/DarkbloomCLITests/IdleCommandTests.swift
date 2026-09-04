import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The idle-memory policy has three writers (`darkbloom idle`, the `start`
/// prompt, `--idle-timeout`) and one authority (`[backend] idle_timeout_mins`).
/// These pin the menu semantics — default = the policy in force, 0 = always
/// ready, custom minutes — and the persistence contract shared with `beta`.
@Suite("Idle-memory policy")
struct IdleCommandTests {

    // MARK: - Menu semantics

    @Test("the pre-selected menu item is the policy currently in force")
    func defaultChoiceTracksCurrentPolicy() {
        #expect(IdleUnloadPolicy.defaultChoice(currentMinutes: 0) == .alwaysReady)
        #expect(IdleUnloadPolicy.defaultChoice(currentMinutes: 60) == .freeWhenIdle)
        #expect(IdleUnloadPolicy.defaultChoice(currentMinutes: 45) == .custom)
        #expect(IdleUnloadPolicy.menuNumber(.alwaysReady) == 1)
        #expect(IdleUnloadPolicy.menuNumber(.freeWhenIdle) == 2)
        #expect(IdleUnloadPolicy.menuNumber(.custom) == 3)
    }

    @Test("choice parsing: blank keeps the default, digits select, junk is rejected")
    func parseChoice() {
        #expect(IdleUnloadPolicy.parseChoice("", fallback: .freeWhenIdle) == .freeWhenIdle)
        #expect(IdleUnloadPolicy.parseChoice("  \n", fallback: .alwaysReady) == .alwaysReady)
        #expect(IdleUnloadPolicy.parseChoice("1", fallback: .freeWhenIdle) == .alwaysReady)
        #expect(IdleUnloadPolicy.parseChoice(" 2 ", fallback: .alwaysReady) == .freeWhenIdle)
        #expect(IdleUnloadPolicy.parseChoice("3", fallback: .freeWhenIdle) == .custom)
        #expect(IdleUnloadPolicy.parseChoice("4", fallback: .freeWhenIdle) == nil)
        #expect(IdleUnloadPolicy.parseChoice("always", fallback: .freeWhenIdle) == nil)
    }

    @Test("minutes parsing: 1...7 days, blank keeps the default, 0 is not a window")
    func parseMinutes() {
        #expect(IdleUnloadPolicy.parseMinutes("", fallback: 60) == 60)
        #expect(IdleUnloadPolicy.parseMinutes("30", fallback: 60) == 30)
        #expect(IdleUnloadPolicy.parseMinutes(" 90 ", fallback: 60) == 90)
        #expect(IdleUnloadPolicy.parseMinutes("0", fallback: 60) == nil)
        #expect(IdleUnloadPolicy.parseMinutes("-5", fallback: 60) == nil)
        #expect(IdleUnloadPolicy.parseMinutes("1.5", fallback: 60) == nil)
        #expect(IdleUnloadPolicy.parseMinutes("\(IdleUnloadPolicy.maxMinutes)", fallback: 60)
            == IdleUnloadPolicy.maxMinutes)
        #expect(IdleUnloadPolicy.parseMinutes("\(IdleUnloadPolicy.maxMinutes + 1)", fallback: 60) == nil)
    }

    @Test("CLI validation accepts 0 and the 7-day ceiling, rejects beyond")
    func validate() {
        #expect(IdleUnloadPolicy.validate(minutes: 0) == nil)
        #expect(IdleUnloadPolicy.validate(minutes: 60) == nil)
        #expect(IdleUnloadPolicy.validate(minutes: IdleUnloadPolicy.maxMinutes) == nil)
        let problem = IdleUnloadPolicy.validate(minutes: IdleUnloadPolicy.maxMinutes + 1)
        #expect(problem?.contains("7 days") == true)
    }

    @Test("window and policy wording")
    func wording() {
        #expect(IdleUnloadPolicy.formatWindow(minutes: 45) == "45 min")
        #expect(IdleUnloadPolicy.formatWindow(minutes: 60) == "1 h")
        #expect(IdleUnloadPolicy.formatWindow(minutes: 90) == "1 h 30 min")
        #expect(IdleUnloadPolicy.formatWindow(minutes: 120) == "2 h")
        #expect(IdleUnloadPolicy.describe(minutes: 0) == "always ready (models stay loaded)")
        #expect(IdleUnloadPolicy.describe(minutes: 60)
            == "free after 1 h idle (models reload on demand)")
    }

    @Test("the menu names all three options and shows the resident footprint")
    func menuText() {
        let menu = IdleUnloadPolicy.menu(holdsGb: 18.2, currentMinutes: 60)
        #expect(menu.contains("1) Always ready"))
        #expect(menu.contains("2) Free when idle"))
        #expect(menu.contains("3) Custom"))
        #expect(menu.contains("Unload after 60 min"))
        #expect(menu.contains("~18 GB"))
        #expect(!menu.contains("currently"))

        // Unknown footprint: no invented number. A custom window in force is
        // echoed so the operator knows what Enter on 3 would keep.
        let custom = IdleUnloadPolicy.menu(holdsGb: nil, currentMinutes: 45)
        #expect(!custom.contains("GB while idle"))
        #expect(custom.contains("(currently 45 min)"))
    }

    // MARK: - Prompt dialogue

    /// Scripted keystrokes → chosen minutes. `emit` output is discarded.
    private func answer(_ lines: [String?], current: UInt64) -> UInt64 {
        var queue = lines
        return Start.resolveIdlePolicyAnswer(
            current: current,
            readInput: { queue.isEmpty ? nil : queue.removeFirst() },
            emit: { _ in })
    }

    @Test("Enter keeps the policy in force")
    func enterKeepsCurrent() {
        #expect(answer([""], current: 60) == 60)
        #expect(answer([""], current: 0) == 0)
        // A custom window in force: Enter on 3, then Enter on the minutes.
        #expect(answer(["", ""], current: 45) == 45)
    }

    @Test("1 → always ready, 2 → free after 60 min")
    func directChoices() {
        #expect(answer(["1"], current: 60) == 0)
        #expect(answer(["2"], current: 0) == 60)
        #expect(answer(["2"], current: 45) == 60)
    }

    @Test("3 asks for minutes; its default is the current window, or 60 from always-ready")
    func customMinutes() {
        #expect(answer(["3", "45"], current: 60) == 45)
        #expect(answer(["3", ""], current: 0) == 60)
        #expect(answer(["3", ""], current: 45) == 45)
        // Bad minutes are re-asked, then accepted.
        #expect(answer(["3", "abc", "0", "90"], current: 60) == 90)
        // Three bad minutes fall back to the custom default.
        #expect(answer(["3", "x", "y", "z"], current: 45) == 45)
    }

    @Test("bad menu answers are re-asked; three misses or EOF keep the current policy")
    func badAnswersAndEOF() {
        #expect(answer(["9", "x", "1"], current: 60) == 0)
        #expect(answer(["9", "x", "y"], current: 60) == 60)
        #expect(answer([nil], current: 45) == 45)
        #expect(answer([], current: 0) == 0)
    }

    // MARK: - Persistence (shares the `beta` contract)

    private func makeTempConfig(_ toml: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("provider.toml")
        if let toml {
            try toml.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Mirrors BetaCommandTests: a non-canonical config path triggers the
    /// legacy→canonical copy when the canonical file is ABSENT; never plant
    /// fixtures in the operator's real config.
    private func withGuardedCanonicalConfig(_ body: () throws -> Void) rethrows {
        let canonical = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/darkbloom/provider.toml")
        let existedBefore = FileManager.default.fileExists(atPath: canonical.path)
        defer {
            if !existedBefore, FileManager.default.fileExists(atPath: canonical.path) {
                try? FileManager.default.removeItem(at: canonical)
            }
        }
        try body()
    }

    @Test("keep-loaded pins idle_timeout_mins = 0 under [backend]")
    func keepLoadedPersistsZero() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "idle-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try withGuardedCanonicalConfig {
            let result = try setIdleUnloadMinutes(0, configPath: url.path)
            #expect(result.changed)
            #expect(result.path == url)
        }
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(tomlKeyPresent(written, section: "backend", key: "idle_timeout_mins"))
        #expect(written.contains("idle_timeout_mins = 0"))
        #expect(try ConfigManager.load(from: url).backend.idleTimeoutMins == 0)
        #expect(idleTimeoutPinned(at: url))
    }

    @Test("the default value is still materialized when the key is absent")
    func defaultIsMaterialized() throws {
        let url = try makeTempConfig("""
            [provider]
            name = "idle-test"
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!idleTimeoutPinned(at: url))

        try withGuardedCanonicalConfig {
            // Decodes to 60 already, but "Free when idle" must be pinned so a
            // future default flip cannot silently move this provider.
            let first = try setIdleUnloadMinutes(60, configPath: url.path)
            #expect(first.changed)
            // Now pinned at the requested value: a true no-op, no rewrite.
            let pinned = try String(contentsOf: url, encoding: .utf8)
            let second = try setIdleUnloadMinutes(60, configPath: url.path)
            #expect(second.changed == false)
            let after = try String(contentsOf: url, encoding: .utf8)
            #expect(after == pinned)
        }
        #expect(idleTimeoutPinned(at: url))
    }

    @Test("a custom window round-trips and replaces the previous value")
    func customWindowRoundTrips() throws {
        let url = try makeTempConfig("""
            [backend]
            idle_timeout_mins = 60
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try withGuardedCanonicalConfig {
            let result = try setIdleUnloadMinutes(45, configPath: url.path)
            #expect(result.changed)
        }
        let config = try ConfigManager.load(from: url)
        #expect(config.backend.idleTimeoutMins == 45)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("idle_timeout_mins = 60"))
    }

    @Test("an out-of-range window is refused before anything is written")
    func outOfRangeIsRefused() throws {
        let url = try makeTempConfig("""
            [backend]
            idle_timeout_mins = 60
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try String(contentsOf: url, encoding: .utf8)

        withGuardedCanonicalConfig {
            #expect(throws: (any Error).self) {
                try setIdleUnloadMinutes(IdleUnloadPolicy.maxMinutes + 1, configPath: url.path)
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }

    @Test("`idle unload-after 0` is rejected in favour of keep-loaded")
    func unloadAfterZeroIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try Idle.UnloadAfter.parse(["0"])
        }
        #expect(throws: Never.self) {
            _ = try Idle.UnloadAfter.parse(["45"])
        }
    }

    // MARK: - status

    @Test("status lists advertised-but-unloaded models with the policy's reason")
    func statusNotLoadedLine() {
        #expect(Status.notLoadedLine(
            advertised: nil, warmModels: [], currentModel: nil, idleTimeoutMins: 60) == nil)
        #expect(Status.notLoadedLine(
            advertised: ["a", "b"], warmModels: ["a"], currentModel: "b", idleTimeoutMins: 60) == nil)

        #expect(Status.notLoadedLine(
            advertised: ["a", "b"], warmModels: ["a"], currentModel: nil, idleTimeoutMins: 60)
            == "Not loaded (unloaded when idle; reloads on demand): b")
        #expect(Status.notLoadedLine(
            advertised: ["a", "b"], warmModels: [], currentModel: nil, idleTimeoutMins: 0)
            == "Not loaded (loads on first request): a, b")
    }
}
