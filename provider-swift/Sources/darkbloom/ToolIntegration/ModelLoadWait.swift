import Darwin
import Foundation
import ProviderCore

/// What the local API's own process says about loading the models it serves: its daemon state (`DaemonStateFile`),
/// read only when that process wrote it (its pid is the one in `local.json`).
struct ModelLoads: Equatable, Sendable {
    /// Loaded now (`DaemonState.warmModels`).
    var loaded: Set<String> = []
    /// Its start's models still to load, the first loading now (`DaemonState.startupPreloadPendingModels`).
    var pending: [String] = []
    /// The coordinator-less server (Only me) loads its models before its API listens, and its state names none.
    var loadsBeforeListening = false

    /// What `state` says, when the process serving the local API (`apiPID`) wrote it; nil otherwise.
    static func reported(by state: DaemonState?, apiPID: Int32?) -> ModelLoads? {
        guard let state, let apiPID, state.pid == apiPID else { return nil }
        if state.servesOnlyItsOwner { return ModelLoads(loadsBeforeListening: true) }
        return ModelLoads(loaded: Set(state.warmModels), pending: state.startupPreloadPendingModels ?? [])
    }

    /// What this Mac's running local API's process says now.
    static func live() -> ModelLoads? {
        reported(by: DaemonStateFile.read(), apiPID: LocalEndpoint.readLiveInfo()?.pid)
    }
}

/// Ctrl-C while the start waits for a model (`ModelLoadWait`). Between `begin` and `end` the signal only presses this
/// watch; before and after, it does what it did.
final class InterruptWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let signalNumber: Int32?
    private var pressed = false
    private var source: DispatchSourceSignal?
    private var previous = sigaction()

    /// `signal` nil: only `press` presses it (tests).
    init(signal: Int32? = nil) {
        signalNumber = signal
    }

    /// The live watch, on SIGINT.
    static func ctrlC() -> InterruptWatch { InterruptWatch(signal: SIGINT) }

    var wasPressed: Bool { lock.withLock { pressed } }

    func press() { lock.withLock { pressed = true } }

    func begin() {
        guard let signalNumber, source == nil else { return }
        sigaction(signalNumber, nil, &previous)
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.press() }
        source.resume()
        self.source = source
    }

    func end() {
        guard let signalNumber, let source else { return }
        source.cancel()
        self.source = nil
        sigaction(signalNumber, &previous, nil)
    }
}

/// The wait's one line on a terminal: drawn again in place (a carriage return, the line, erase to its end), never
/// wider than the window, and erased when the wait ends.
struct LiveLine {
    var write: (String) -> Void
    var columns: () -> Int = { 80 }

    func show(_ text: String) {
        let width = max(10, columns() - 1)
        write("\r\u{1B}[2K" + (text.count <= width ? text : String(text.prefix(width - 1)) + "…"))
    }

    func erase() { write("\r\u{1B}[2K") }

    /// Standard output, when it is a terminal that can draw a line again (not `TERM=dumb`); nil otherwise.
    static var standardOutput: LiveLine? {
        guard isatty(STDOUT_FILENO) != 0, ProcessInfo.processInfo.environment["TERM"] != "dumb" else { return nil }
        return LiveLine(write: { text in
            print(text, terminator: "")
            fflush(stdout)
        }, columns: {
            var size = winsize()
            guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
            return Int(size.ws_col)
        })
    }
}

/// Before `darkbloom --opencode` / `--hermes` write a tool's config, they wait while the local API's process still loads
/// this Mac's models at its start: until a model is loaded, this Mac's `/v1/models` gives none of its own limits, and
/// the tools would get the catalog's. One live line on a terminal, else one line as it starts and one as it ends; at most
/// `timeout`; Ctrl-C ends it. A model that isn't loading (one that unloads when idle, or loads on a request) isn't
/// waited for.
struct ModelLoadWait {
    enum Outcome: Equatable, Sendable {
        /// Nothing of this Mac's is loading now: set the tools up with what it lists. `waited`: after a wait, when this
        /// Mac's list has changed since it was read.
        case ready(waited: Bool)
        /// The model it waited for didn't load.
        case notLoaded(model: String)
        /// The model is still loading at the deadline.
        case timedOut(model: String)
        /// Ctrl-C while it waited for the model.
        case interrupted(model: String)
    }

    /// What the local API's process says, at each look.
    var loads: () -> ModelLoads?
    var timeout: TimeInterval = ModelLoadWait.defaultTimeout
    /// Seconds on a monotonic clock.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Between two looks; the spinner turns once per look.
    var pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    var interrupt = InterruptWatch()
    /// Nil without a terminal.
    var liveLine: LiveLine?

    /// The longest wait. A model's load takes from seconds to a few minutes; past this, something else is wrong.
    static let defaultTimeout: TimeInterval = 600
    /// Right after its local API answers, a provider may not have said yet what it loads: an answer that names nothing
    /// loaded and nothing to load is asked once more, this long after.
    static let settleSeconds: TimeInterval = 1
    static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// As `start` waits: the local API's own process, the terminal's live line, and Ctrl-C.
    static func live() -> ModelLoadWait {
        ModelLoadWait(loads: { ModelLoads.live() }, interrupt: .ctrlC(), liveLine: .standardOutput)
    }

    /// Waits while the local API's process loads any of `thisMac` (this Mac's models as its `/v1/models` lists them)
    /// for its start. `name` gives a model's name for the lines, `say` prints a whole line.
    func run(thisMac: [String], tools: [IntegrationTool], name: (String) -> String,
             say: (String) -> Void) async -> Outcome {
        guard !thisMac.isEmpty else { return .ready(waited: false) }
        interrupt.begin()
        defer { interrupt.end() }
        let start = clock()
        var awaited: [String] = []
        var emptySince: TimeInterval?
        var frame = 0
        while true {
            let now = clock()
            let report = loads()
            let loading = report.map { report in
                report.pending.filter { thisMac.contains($0) && !report.loaded.contains($0) }
            } ?? []
            if loading.isEmpty {
                // An answer that names a model loaded, or that follows the models this wait saw loading, stands; any
                // other stands once it is given again a second later.
                let settled = !awaited.isEmpty || report.map { $0.loadsBeforeListening || !$0.loaded.isEmpty } == true
                if settled || emptySince.map({ now - $0 >= Self.settleSeconds }) == true {
                    return finish(awaited: awaited, loaded: report?.loaded ?? [], elapsed: now - start, name: name,
                                  say: say)
                }
                if emptySince == nil { emptySince = now }
            }
            let model = loading.first ?? awaited.first ?? thisMac[0]
            if interrupt.wasPressed { return end(.interrupted(model: model)) }
            if !loading.isEmpty {
                if now - start >= timeout { return end(.timedOut(model: model)) }
                if awaited.isEmpty, liveLine == nil { say(Self.startLine(name(model), tools: tools, timeout: timeout)) }
                for id in loading where !awaited.contains(id) { awaited.append(id) }
                emptySince = nil
                liveLine?.show("\(Self.spinner[frame % Self.spinner.count]) "
                    + Self.loadingLine(name(model), tools: tools, elapsed: now - start))
                frame += 1
            }
            await pause()
        }
    }

    /// The wait ended with nothing loading: the models it waited for that loaded, or the first that didn't.
    private func finish(awaited: [String], loaded: Set<String>, elapsed: TimeInterval, name: (String) -> String,
                        say: (String) -> Void) -> Outcome {
        guard !awaited.isEmpty else { return .ready(waited: false) }
        let done = awaited.filter(loaded.contains)
        guard !done.isEmpty else { return end(.notLoaded(model: awaited[0])) }
        liveLine?.erase()
        say(Self.loadedLine(done.map(name), elapsed: elapsed))
        return .ready(waited: true)
    }

    private func end(_ outcome: Outcome) -> Outcome {
        liveLine?.erase()
        return outcome
    }

    // MARK: - Words

    /// The live line, after its spinner: `Loading Gemma 4 26B before setting up OpenCode… 42s`.
    static func loadingLine(_ model: String, tools: [IntegrationTool], elapsed: TimeInterval) -> String {
        "Loading \(model) before setting up \(ToolIntegrationStep.names(tools))… \(duration(elapsed))"
    }

    /// Without a terminal, as the wait starts.
    static func startLine(_ model: String, tools: [IntegrationTool], timeout: TimeInterval) -> String {
        "Waiting up to \(DurationFormatting.compact(timeout)) for \(model) to load before setting up "
            + "\(ToolIntegrationStep.names(tools))."
    }

    /// The models it waited for are loaded.
    static func loadedLine(_ models: [String], elapsed: TimeInterval) -> String {
        "\(list(models)) loaded after \(duration(elapsed))."
    }

    /// The model was still loading at the deadline; nothing was written.
    static func stillLoading(_ model: String, tools: [IntegrationTool], after seconds: TimeInterval) -> String {
        "✗ \(model) is still loading after \(DurationFormatting.compact(seconds)), so "
            + "\(ToolIntegrationStep.notSetUp(tools)). Run `\(ToolIntegrationStep.command(tools))` again once "
            + "`\(ToolIntegrationStep.cli) status` shows it loaded."
    }

    /// The model it waited for didn't load; nothing was written.
    static func didNotLoad(_ model: String, tools: [IntegrationTool]) -> String {
        "✗ \(model) didn't load, so \(ToolIntegrationStep.notSetUp(tools)): `\(ToolIntegrationStep.cli) status` says why."
    }

    /// Ctrl-C while it waited; nothing was written.
    static func stopped(_ model: String, tools: [IntegrationTool]) -> String {
        "Stopped waiting for \(model) to load, so \(ToolIntegrationStep.notSetUp(tools)); nothing was written. Run "
            + "`\(ToolIntegrationStep.command(tools))` again once `\(ToolIntegrationStep.cli) status` shows it loaded."
    }

    /// `42s`, `1m 12s`, `10m 0s`.
    static func duration(_ seconds: TimeInterval) -> String {
        DurationFormatting.compact(seconds, secondsInMinuteRange: true, elideZeroMinutesInHourRange: false)
    }

    /// `A`, `A and B`, `A, B and C`.
    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
