import Darwin
import Foundation
import ProviderCore

/// What the local API's own process says about loading the models it serves. Skeleton: it says nothing yet.
struct ModelLoads: Equatable, Sendable {
    var loaded: Set<String> = []
    var pending: [String] = []
    var loadsBeforeListening = false

    static func reported(by state: DaemonState?, apiPID: Int32?) -> ModelLoads? { nil }

    static func live() -> ModelLoads? { nil }
}

/// Ctrl-C while the start waits for a model. Skeleton: takes no signal.
final class InterruptWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed = false

    init(signal: Int32? = nil) {}

    static func ctrlC() -> InterruptWatch { InterruptWatch(signal: SIGINT) }

    var wasPressed: Bool { lock.withLock { pressed } }

    func press() { lock.withLock { pressed = true } }

    func begin() {}

    func end() {}
}

/// The wait's one line on a terminal.
struct LiveLine {
    var write: (String) -> Void
    var columns: () -> Int = { 80 }

    func show(_ text: String) {
        let width = max(10, columns() - 1)
        write("\r\u{1B}[2K" + (text.count <= width ? text : String(text.prefix(width - 1)) + "…"))
    }

    func erase() { write("\r\u{1B}[2K") }

    static var standardOutput: LiveLine? { nil }
}

/// The wait before a tool's config is written. Skeleton: it never waits.
struct ModelLoadWait {
    enum Outcome: Equatable, Sendable {
        case ready(waited: Bool)
        case notLoaded(model: String)
        case timedOut(model: String)
        case interrupted(model: String)
    }

    var loads: () -> ModelLoads?
    var timeout: TimeInterval = ModelLoadWait.defaultTimeout
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    var interrupt = InterruptWatch()
    var liveLine: LiveLine?

    static let defaultTimeout: TimeInterval = 600
    static let settleSeconds: TimeInterval = 1

    static func live() -> ModelLoadWait { ModelLoadWait(loads: { nil }) }

    func run(thisMac: [String], tools: [IntegrationTool], name: (String) -> String,
             say: (String) -> Void) async -> Outcome {
        .ready(waited: false)
    }

    static func loadingLine(_ model: String, tools: [IntegrationTool], elapsed: TimeInterval) -> String {
        "Loading \(model) before setting up \(ToolIntegrationStep.names(tools))… \(duration(elapsed))"
    }

    static func loadedLine(_ models: [String], elapsed: TimeInterval) -> String {
        "\(list(models)) loaded after \(duration(elapsed))."
    }

    static func duration(_ seconds: TimeInterval) -> String {
        DurationFormatting.compact(seconds, secondsInMinuteRange: true, elideZeroMinutesInHourRange: false)
    }

    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
