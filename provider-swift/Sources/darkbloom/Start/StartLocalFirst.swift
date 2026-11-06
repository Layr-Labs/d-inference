import ArgumentParser
import Foundation
import ProviderCore

// How a single-Mac `darkbloom start` serves (`[local]`): only its owner, the Darkbloom network, or both with the
// owner first. A flag decides it for one start; otherwise the saved choice; otherwise, in a terminal, one question,
// whose answer is saved. Without a terminal and without a saved choice, a start keeps today's behaviour: the
// Darkbloom network, with no local API.
//
// Red skeleton: the types compile, but nothing is asked, chosen, saved or said yet; every start serves as its flags
// said before `[local]`.

/// The `start` options that decide how this Mac serves.
struct LocalFirstOptions: Equatable, Sendable {
    var local = false
    var localEndpoint = false
    var network = false
    /// `--me-first` (true) or `--no-me-first` (false).
    var meFirst: Bool?
    var meFirstIdleMinutes: UInt64?
    var route: LocalSettings.Route?
    var choose = false
    var port: UInt16?
    var bind: String?
    var noAuth = false
    /// launchd's child: its flags say how it serves; it never asks and never saves.
    var foreground = false

    /// The mode a flag names, and that flag. `--me-first` and `--local-endpoint` both name Both.
    var flagMode: (mode: LocalSettings.Mode, flag: String)? {
        if local { return (.local, "--local") }
        if localEndpoint { return (.both, "--local-endpoint") }
        return nil
    }

    /// Why these options can't be used together, in plain words; nil when they can.
    var conflict: String? { nil }

    /// How this start's mode is decided.
    func modeStep(saved: LocalSettings?, terminal: Bool) throws -> ServingStep {
        if let named = flagMode { return .decided(named.mode, .flag(named.flag)) }
        return .decided(LocalSettings.launchMode(local: false, localEndpoint: false), .today)
    }
}

/// Where a start's mode came from.
enum ServingModeSource: Equatable, Sendable {
    /// `--local`, `--network`, `--me-first` or `--local-endpoint`, for this start only.
    case flag(String)
    /// `[local] mode`.
    case saved
    /// Answered now, in a terminal, and saved.
    case question
    /// Nothing chose it (no terminal, no saved choice): today's behaviour.
    case today
}

/// A start's first step: a mode, or the question.
enum ServingStep: Equatable, Sendable {
    case decided(LocalSettings.Mode, ServingModeSource)
    case ask(preselected: LocalSettings.Mode)
}

/// The `[local]` keys a start saves; empty when it saves nothing.
struct LocalSettingsChange: Equatable, Sendable {
    var mode: LocalSettings.Mode?
    var route: LocalSettings.Route?
    var port: UInt16?
    var meFirst: Bool?
    var meFirstIdleMinutes: UInt64?

    var isEmpty: Bool { self == LocalSettingsChange() }

    func apply(to settings: inout LocalSettings) {}
}

/// How a start serves, decided before anything starts or is saved.
struct StartServing: Equatable, Sendable {
    var mode: LocalSettings.Mode
    var source: ServingModeSource
    var meFirst: Bool
    var meFirstIdleMinutes: UInt64
    var route: LocalSettings.Route?
    var accountKeySaved: Bool?
    var port: UInt16
    var bind: String
    var noAuth: Bool
    var change = LocalSettingsChange()
    var portNote: String?

    var hasLocalAPI: Bool { mode != .network }

    var baseURL: String { "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1" }

    var launchAgentEndpoint: LaunchAgent.LocalEndpointOptions {
        LaunchAgent.LocalEndpointOptions(enabled: mode == .both, port: port, bind: bind, noAuth: noAuth)
    }

    var summaryLines: [String] { [] }
}

/// What resolving a start may touch: tests stand in for the terminal, the Keychain and the ports.
struct ServingEnvironment {
    var terminal: Bool
    var readInput: () -> String?
    var emit: (String) -> Void
    var accountKeySaved: () -> Bool
    var ownLivePort: () -> UInt16?
    var isFree: (UInt16) -> Bool
}

enum StartServingResolver {
    static func resolve(_ options: LocalFirstOptions, saved section: LocalSettings?,
                        environment env: ServingEnvironment) throws -> StartServing? {
        let mode: LocalSettings.Mode, source: ServingModeSource
        switch try options.modeStep(saved: section, terminal: env.terminal) {
        case .decided(let decided, let from): (mode, source) = (decided, from)
        case .ask(let preselected): (mode, source) = (preselected, .question)
        }
        return StartServing(mode: mode, source: source, meFirst: false,
                            meFirstIdleMinutes: LocalSettings.defaultMeFirstIdleMinutes, route: nil,
                            accountKeySaved: nil, port: options.port ?? BuildEnvironment.current.defaultLocalPort,
                            bind: options.bind ?? LocalSettings.defaultBind, noAuth: options.noAuth)
    }
}

/// The port of a local API a start creates.
enum LocalAPIPort {
    static let neverChosen: Set<UInt16> = []
    static let span: UInt16 = 20

    static func pick(from start: UInt16, ownLivePort: UInt16?, isFree: (UInt16) -> Bool) -> UInt16? { start }

    static func note(chosen: UInt16, start: UInt16) -> String { "" }

    static func noneFree(from start: UInt16) -> String { "" }
}

/// `[local]` from the config at `configPath`; the skeleton reads nothing.
func savedLocalSettings(configPath rawPath: String?) throws -> LocalSettings? { nil }

/// The start screen's question, and the route follow-up.
enum ServingQuestion {
    static func modeLines(idleMinutes: UInt64) -> [String] { [] }

    static let routeLines: [String] = []

    static func prompt(preselected number: Int) -> String { "" }

    static let retry = ""

    static let cancelled = ""
}

/// Plain words for how this Mac serves, shared by `start`, `status` and `local`.
enum LocalFirstWords {
    static func minutes(_ count: UInt64) -> String { "" }

    static func idleMinutes(milliseconds: Int64) -> UInt64 { 0 }

    static func requests(route: LocalSettings.Route?, accountKeySaved: Bool) -> String { "" }

    static func serving(mode: LocalSettings.Mode, meFirst: Bool, idleMinutes: UInt64) -> String { "" }
}
