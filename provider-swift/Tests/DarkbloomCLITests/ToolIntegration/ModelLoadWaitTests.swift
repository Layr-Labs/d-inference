import Darwin
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// A temp home with Darkbloom's key file, a clock that moves only between looks, a local API process that answers as
/// scripted, and recorders for what the step says and what its live line draws. No tool runs, no port is bound, no
/// state file is read and no signal is taken.
private final class WaitSandbox: @unchecked Sendable {
    static let gemma = "gemma-4-26b-qat-4bit"
    static let loading = ModelLoads(pending: [gemma])
    static let loaded = ModelLoads(loaded: [gemma])

    let directory: TemporaryDirectory
    let home: URL
    let keyFile: URL
    let interrupt = InterruptWatch()
    var said: [String] = []
    var drawn: [String] = []
    var now: TimeInterval = 1_000
    var looks = 0
    /// Reads of this Mac's `/v1/models`.
    var reads = 0

    init() throws {
        directory = try TemporaryDirectory("tools-wait")
        home = directory.file("home")
        keyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
    }

    var endpoint: IntegrationEndpoint { IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile) }
    var openCodeFile: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }

    /// The catalog says 131,072 tokens for Gemma; this Mac serves its whole window, 262,144.
    static let catalog = CatalogSnapshot(models: [
        CatalogModel(id: gemma, s3Name: gemma, displayName: "Gemma 4 26B", sizeGb: 1, maxContextLength: 131_072,
                     maxOutputLength: 32_768, capabilities: ["tools", "vision", "reasoning"]),
    ], aliases: [])

    /// The local API's process answers `answers` in turn, the last again and again; Ctrl-C at look `pressAt`.
    func wait(_ answers: [ModelLoads?], timeout: TimeInterval = ModelLoadWait.defaultTimeout, terminal: Bool = false,
              pressAt: Int? = nil) -> ModelLoadWait {
        ModelLoadWait(
            loads: { [self] in
                defer { looks += 1 }
                if looks == pressAt { interrupt.press() }
                return answers[min(looks, answers.count - 1)]
            },
            timeout: timeout, clock: { [self] in now }, pause: { [self] in now += 0.25 }, interrupt: interrupt,
            liveLine: terminal ? LiveLine(write: { [self] in drawn.append($0) }, columns: { 120 }) : nil)
    }

    /// The step, with OpenCode and Hermes installed; this Mac lists Gemma with its window once the process says it is
    /// loaded (`loadedFromRead`: the read of `/v1/models` from which it does).
    func step(_ tools: [IntegrationTool], wait: ModelLoadWait?, loadedFromRead: Int = 2) -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: tools, environment: ToolIntegrationEnvironment(home: home, variables: [:]), provider: F.provider,
            findTool: { .installed(URL(fileURLWithPath: "/fake/\($0.rawValue)")) },
            fetchModels: { [self] _ in
                reads += 1
                return [EndpointModel(id: Self.gemma, ownedBy: "this-mac",
                                      contextLength: reads >= loadedFromRead ? 262_144 : nil)]
            },
            fetchCatalog: { Self.catalog }, say: { [self] in said.append($0) }, modelLoadWait: wait)
    }

    /// Every file but the key file.
    func filesOtherThanTheKey() -> [URL] {
        directory.allFiles().filter { $0.resolvingSymlinksInPath().path != keyFile.resolvingSymlinksInPath().path }
    }
}

@Suite("Start: --opencode and --hermes wait for this Mac's models to load", .serialized)
struct ModelLoadWaitTests {
    // MARK: - Wait, then write

    @Test("a model still loading: the step waits for it, then writes the limits this Mac gives it")
    func waitsThenWritesTheModelsOwnLimits() async throws {
        let sandbox = try WaitSandbox()
        let loading = WaitSandbox.loading
        let wait = sandbox.wait([loading, loading, loading, loading, WaitSandbox.loaded])
        #expect(await sandbox.step([.opencode], wait: wait).run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        #expect(sandbox.reads == 2, "the list is read again once the model is loaded")
        let written = F.utf8(try Data(contentsOf: sandbox.openCodeFile))
        #expect(written.contains("\"limit\": { \"context\": 262144, \"output\": 32768 }"),
                "this Mac's window, not the catalog's 131,072")
        #expect(Array(sandbox.said.prefix(3)) == [
            "Waiting up to 10m for Gemma 4 26B to load before setting up OpenCode.",
            "Gemma 4 26B loaded after 1s.",
            "✓ OpenCode can use Darkbloom: 1 model.",
        ])
        #expect(!sandbox.said.contains { $0.contains("again once") }, "nothing to run again")
    }

    @Test("nothing loading: the tools are set up at once, without a wait or a line about it")
    func nothingLoadingNoWait() async throws {
        let sandbox = try WaitSandbox()
        #expect(await sandbox.step([.opencode], wait: sandbox.wait([WaitSandbox.loaded]), loadedFromRead: 1)
            .run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        #expect(sandbox.looks == 1 && sandbox.reads == 1 && sandbox.now == 1_000)
        #expect(sandbox.said.first == "✓ OpenCode can use Darkbloom: 1 model.")

        // The coordinator-less server (Only me) loads its models before it listens: once it answers, nothing is left.
        let onlyMe = try WaitSandbox()
        #expect(await onlyMe.step([.opencode], wait: onlyMe.wait([ModelLoads(loadsBeforeListening: true)]),
                                  loadedFromRead: 1).run(endpoint: onlyMe.endpoint, requests: "this Mac only"))
        #expect(onlyMe.looks == 1 && onlyMe.said.first == "✓ OpenCode can use Darkbloom: 1 model.")
    }

    @Test("a provider that hasn't said what it loads yet is asked again a second later, then waited for")
    func anEmptyAnswerIsAskedAgain() async throws {
        // Right after its API answers: no state of its own yet, then its start's plan.
        let sandbox = try WaitSandbox()
        let wait = sandbox.wait([nil, WaitSandbox.loading, WaitSandbox.loading, WaitSandbox.loaded])
        #expect(await sandbox.step([.opencode], wait: wait).run(endpoint: sandbox.endpoint, requests: "x"))
        #expect(sandbox.said.prefix(2) == ["Waiting up to 10m for Gemma 4 26B to load before setting up OpenCode.",
                                           "Gemma 4 26B loaded after 0s."])

        // No word at all, or nothing loaded and nothing to load (it unloads when idle): set up after the second look.
        for answer in [nil, ModelLoads()] as [ModelLoads?] {
            let quiet = try WaitSandbox()
            #expect(await quiet.step([.opencode], wait: quiet.wait([answer]), loadedFromRead: 1)
                .run(endpoint: quiet.endpoint, requests: "x"))
            #expect(quiet.now - 1_000 >= ModelLoadWait.settleSeconds && quiet.now - 1_000 < 2, "\(String(describing: answer))")
            #expect(quiet.reads == 1 && quiet.said.first == "✓ OpenCode can use Darkbloom: 1 model.")
        }
    }

    // MARK: - Nothing written

    @Test("still loading at the deadline: the message names the next step, and nothing is written")
    func timeoutSaysSoAndWritesNothing() async throws {
        let sandbox = try WaitSandbox()
        let wait = sandbox.wait([WaitSandbox.loading], timeout: 5)
        #expect(await !sandbox.step([.opencode, .hermes], wait: wait).run(endpoint: sandbox.endpoint, requests: "x"))
        #expect(sandbox.said == [
            "Waiting up to 5s for Gemma 4 26B to load before setting up OpenCode and Hermes.",
            "✗ Gemma 4 26B is still loading after 5s, so OpenCode and Hermes weren't set up. Run "
                + "`darkbloom --opencode --hermes` again once `darkbloom status` shows it loaded.",
            "Darkbloom keeps serving.",
        ])
        #expect(sandbox.now - 1_000 == 5)
        #expect(sandbox.filesOtherThanTheKey().isEmpty)
        #expect(ModelLoadWait.defaultTimeout == 600)
    }

    @Test("Ctrl-C while it waits: nothing is written, and the start says so")
    func ctrlCWritesNothing() async throws {
        let sandbox = try WaitSandbox()
        let wait = sandbox.wait([WaitSandbox.loading], terminal: true, pressAt: 3)
        #expect(await !sandbox.step([.opencode], wait: wait).run(endpoint: sandbox.endpoint, requests: "x"))
        #expect(sandbox.said == [
            "Stopped waiting for Gemma 4 26B to load, so OpenCode wasn't set up; nothing was written. Run "
                + "`darkbloom --opencode` again once `darkbloom status` shows it loaded.",
            "Darkbloom keeps serving.",
        ])
        #expect(sandbox.drawn.last == "\r\u{1B}[2K", "the live line is erased")
        #expect(sandbox.filesOtherThanTheKey().isEmpty)
    }

    @Test("a model it waited for that didn't load: nothing is written, and `status` says why")
    func notLoadedWritesNothing() async throws {
        let sandbox = try WaitSandbox()
        let wait = sandbox.wait([WaitSandbox.loading, WaitSandbox.loading, ModelLoads()])
        #expect(await !sandbox.step([.opencode], wait: wait).run(endpoint: sandbox.endpoint, requests: "x"))
        #expect(sandbox.said == [
            "Waiting up to 10m for Gemma 4 26B to load before setting up OpenCode.",
            "✗ Gemma 4 26B didn't load, so OpenCode wasn't set up: `darkbloom status` says why.",
            "Darkbloom keeps serving.",
        ])
        #expect(sandbox.filesOtherThanTheKey().isEmpty)
    }

    // MARK: - The line

    @Test("on a terminal one live line, drawn in place; without one, a line as it starts and one as it ends")
    func oneLiveLineOnlyOnATerminal() async throws {
        let answers = [WaitSandbox.loading, WaitSandbox.loading, WaitSandbox.loading, WaitSandbox.loaded]
        let plain = try WaitSandbox()
        #expect(await plain.step([.opencode], wait: plain.wait(answers)).run(endpoint: plain.endpoint, requests: "x"))
        #expect(plain.drawn.isEmpty)
        #expect(Array(plain.said.prefix(2)) == ["Waiting up to 10m for Gemma 4 26B to load before setting up OpenCode.",
                                                "Gemma 4 26B loaded after 0s."])
        #expect(!plain.said.joined().contains("\r") && !plain.said.joined().contains("\u{1B}"))

        let terminal = try WaitSandbox()
        #expect(await terminal.step([.opencode], wait: terminal.wait(answers, terminal: true))
            .run(endpoint: terminal.endpoint, requests: "x"))
        let line = "Loading Gemma 4 26B before setting up OpenCode… 0s"
        #expect(terminal.drawn == ["\r\u{1B}[2K⠋ " + line, "\r\u{1B}[2K⠙ " + line, "\r\u{1B}[2K⠹ " + line,
                                   "\r\u{1B}[2K"])
        #expect(terminal.said.first == "Gemma 4 26B loaded after 0s.", "no start line beside the live one")
    }

    @Test("the live line says how long it has waited, and never runs past the window")
    func liveLineWords() {
        #expect(ModelLoadWait.loadingLine("Gemma 4 26B", tools: [.opencode, .hermes], elapsed: 72)
            == "Loading Gemma 4 26B before setting up OpenCode and Hermes… 1m 12s")
        var drawn: [String] = []
        LiveLine(write: { drawn.append($0) }, columns: { 21 }).show("Loading Gemma 4 26B before setting up OpenCode")
        #expect(drawn == ["\r\u{1B}[2KLoading Gemma 4 26B…"])
        #expect(ModelLoadWait.loadedLine(["Gemma 4 26B", "Qwen 3.8 27B", "GLM-5.3-Flash"], elapsed: 125)
            == "Gemma 4 26B, Qwen 3.8 27B and GLM-5.3-Flash loaded after 2m 5s.")
    }

    // MARK: - What the local API's process says

    @Test("only the local API's own process is believed, and Only me's server has loaded before it listens")
    func theAPIsOwnProcessSays() {
        let loop = DaemonState(pid: 42, version: "test", writtenAt: 0, startedAt: 0, warmModels: ["a"],
                               startupPreloadPendingModels: ["b", "c"], runtimeCapabilities: [])
        #expect(ModelLoads.reported(by: loop, apiPID: 42) == ModelLoads(loaded: ["a"], pending: ["b", "c"]))
        #expect(ModelLoads.reported(by: loop, apiPID: 7) == nil, "another process's state")
        #expect(ModelLoads.reported(by: loop, apiPID: nil) == nil, "no local API")
        #expect(ModelLoads.reported(by: nil, apiPID: 42) == nil)
        let onlyMe = DaemonState(pid: 42, version: "test", writtenAt: 0, startedAt: 0)
        #expect(ModelLoads.reported(by: onlyMe, apiPID: 42) == ModelLoads(loadsBeforeListening: true))
    }

    @Test("the step `start` runs waits")
    func startsStepWaits() {
        #expect(ToolIntegrationStep.live(tools: [.opencode], coordinatorURL: "wss://coordinator.invalid/ws/provider")
            .modelLoadWait != nil)
    }

    @Test("a model this Mac doesn't list, or one already loaded, isn't waited for")
    func onlyThisMacsLoadingModelsAreWaitedFor() async {
        var looks = 0
        let wait = ModelLoadWait(loads: {
            looks += 1
            return ModelLoads(loaded: ["warm"], pending: ["warm", "elsewhere"])
        }, clock: { 0 }, pause: {})
        let outcome = await wait.run(thisMac: ["warm", "listed"], tools: [.opencode], name: { $0 }, say: { _ in })
        #expect(outcome == .ready(waited: false) && looks == 1)
        // This Mac lists none of its own (a relay): nothing to ask.
        #expect(await ModelLoadWait(loads: { Issue.record("asked"); return nil }).run(
            thisMac: [], tools: [.opencode], name: { $0 }, say: { _ in }) == .ready(waited: false))
    }

    @Test("the live watch takes the signal only while it waits, then gives it back as it was")
    func theWatchTakesTheSignalOnlyWhileItWaits() async throws {
        // SIGUSR2 stands in for SIGINT, so no other test's handler sees it.
        let before = signal(SIGUSR2, SIG_DFL)
        defer { signal(SIGUSR2, before) }
        let watch = InterruptWatch(signal: SIGUSR2)
        watch.begin()
        // Raised only once the watch has it: the signal's default action would end the test process.
        try #require(ProviderStopSignals.isIgnored(SIGUSR2), "the default action can't end the process while it waits")
        raise(SIGUSR2)
        for _ in 0..<200 where !watch.wasPressed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(watch.wasPressed)
        watch.end()
        #expect(!ProviderStopSignals.isIgnored(SIGUSR2), "the default action is back")
    }
}
