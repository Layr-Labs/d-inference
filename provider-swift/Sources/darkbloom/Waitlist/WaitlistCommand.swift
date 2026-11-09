import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom waitlist [<name>]`: the waitlists of the coordinator's catalog,
/// which an account joins, not a Mac. Without a name it lists them; with one
/// it puts the account on that waitlist and shows where it stands.

/// The calls to the coordinator's waitlists. `live` asks the coordinator of
/// this Mac's provider configuration with its login token; tests replace the
/// calls.
struct FeatureWaitlistAccess: Sendable {
    /// The coordinator asked, for the lines that name it.
    var coordinator: String
    /// Every waitlist with the account's place on it.
    var waitlists: @Sendable () async -> Result<FeatureWaitlists, FeatureWaitlistProblem>
    /// The account's place on the waitlist `feature`.
    var place: @Sendable (_ feature: String) async -> FeatureWaitlistLookup
    /// Puts the account on the waitlist `feature`.
    var join: @Sendable (_ feature: String) async -> FeatureWaitlistLookup

    /// The waitlists of the coordinator of the provider configuration at
    /// `configPath`, or of the default one.
    static func live(configPath: String? = nil) -> FeatureWaitlistAccess {
        let coordinatorURL: String
        do {
            let path = try configPath.map { URL(fileURLWithPath: $0) } ?? ConfigManager.defaultConfigPath()
            coordinatorURL = try ConfigManager.loadOrDefaults(from: path).coordinator.url
        } catch {
            return failing(BuildEnvironment.current.coordinatorHTTPURL, "could not read the provider configuration: \(error)")
        }
        let httpBase = coordinatorHTTPBase(coordinatorURL)
        guard let base = FeatureWaitlistClient.base(httpBase: httpBase) else {
            return failing(httpBase, "the coordinator URL must be https, or http to this Mac")
        }
        let client = FeatureWaitlistClient(base: base, token: AuthTokenStore.load())
        return FeatureWaitlistAccess(
            coordinator: httpBase,
            waitlists: { await client.waitlists() },
            place: { feature in await client.place(feature) },
            join: { feature in await client.join(feature) })
    }

    private static func failing(_ coordinator: String, _ reason: String) -> FeatureWaitlistAccess {
        let problem = FeatureWaitlistProblem.unavailable(reason)
        return FeatureWaitlistAccess(coordinator: coordinator, waitlists: { .failure(problem) },
                                     place: { _ in .failure(problem) }, join: { _ in .failure(problem) })
    }
}

/// What `darkbloom waitlist` does: ask, then print the answer or why there
/// is none.
struct FeatureWaitlistCommand {
    let access: FeatureWaitlistAccess
    let view: FeatureWaitlistView
    let json: Bool
    /// Where its lines go: standard output, and standard error for a problem. The desktop app's `waitlist_join` keeps
    /// them for its operation (`DesktopBackend.joinWaitlist`).
    var say: @Sendable (String) -> Void = { print($0) }
    var warn: @Sendable (String) -> Void = { printError($0) }

    /// Every waitlist and where the account stands on it.
    func list() async throws {
        let waitlists = try answer(await access.waitlists(), title: nil)
        guard json else {
            view.list(waitlists.data).forEach(say)
            return
        }
        try printDocument(waitlists)
    }

    /// Puts the account on the waitlist `name` names and shows where it
    /// stands. The coordinator keeps a place the account already has and
    /// leaves an approved or revoked account as it is; a revoked account is
    /// shown its state but is not on the waitlist, so the command fails.
    func join(_ name: String) async throws {
        let waitlist = try await waitlist(named: name)
        let place = try answer(await access.join(waitlist.feature), title: waitlist.title)
        if json {
            try printDocument(place)
        } else {
            view.lines(place, name: name.lowercased()).forEach(say)
        }
        if place.status == .revoked { throw ExitCode.failure }
    }

    /// The catalog's waitlist that `name` names; an unknown name says which
    /// waitlists there are.
    private func waitlist(named name: String) async throws -> FeatureWaitlistPlace {
        let waitlists = try answer(await access.waitlists(), title: nil)
        guard let waitlist = waitlists.named(name) else {
            view.unknown(name, among: waitlists.data).forEach(warn)
            throw ExitCode.failure
        }
        return waitlist
    }

    /// The answer, or its problem printed and the command failed. `title`
    /// names the waitlist the call was about.
    private func answer<Answer>(_ result: Result<Answer, FeatureWaitlistProblem>, title: String?) throws -> Answer {
        switch result {
        case .success(let answer):
            return answer
        case .failure(let problem):
            view.problem(problem, title: title).forEach(warn)
            throw ExitCode.failure
        }
    }

    /// The coordinator's answer as JSON, times in ISO 8601, with no control
    /// or format character written raw.
    private func printDocument(_ document: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        say(FeatureWaitlistView.escapingUnprintable(json: String(decoding: try encoder.encode(document), as: UTF8.self)))
    }
}

extension FeatureWaitlistCommand {
    /// The command for the coordinator of the provider configuration at
    /// `configPath`, or of the default one.
    init(configPath: String?, json: Bool) {
        let access = FeatureWaitlistAccess.live(configPath: configPath)
        self.init(access: access, view: FeatureWaitlistView(cli: BuildEnvironment.current.cliName, coordinator: access.coordinator),
                  json: json)
    }
}

/// `darkbloom waitlist`: the waitlists Darkbloom approves accounts from. The
/// coordinator lists them, so the names are arguments, not subcommands.
struct Waitlist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the waitlists Darkbloom approves accounts from, or join one.",
        discussion: """
        Darkbloom opens some features, such as clusters and Darkbloom Sandbox, to the accounts it approves \
        from a waitlist; the coordinator lists the waitlists. A waitlist is for your account, not for a Mac: \
        joining sends nothing about this Mac. Without a name, this command shows each waitlist and where your \
        account stands. With a name, it puts your account on that waitlist and shows where it stands; running \
        it again keeps your place. Use a Mac linked to your account (`\(BuildEnvironment.current.cliName) login`); \
        `\(BuildEnvironment.current.cliName) sandbox setup` installs nothing, and `\(BuildEnvironment.current.cliName) cluster` \
        sets up no new pair through Darkbloom, until Darkbloom approves the account; Macs already paired, and \
        `\(BuildEnvironment.current.cliName) cluster local`, keep working without it.

        Examples:
          \(BuildEnvironment.current.cliName) waitlist
          \(BuildEnvironment.current.cliName) waitlist cluster
          \(BuildEnvironment.current.cliName) waitlist sandbox
        """)

    @Argument(help: ArgumentHelp(
        "The waitlist to join, by its id as the list shows it in parentheses, such as cluster or sandbox. "
            + "Without one, lists every waitlist.",
        valueName: "name"))
    var name: String?

    @Flag(help: "Print the coordinator's answer as JSON.")
    var json = false

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let command = FeatureWaitlistCommand(configPath: configOptions.config, json: json)
        guard let name else {
            try await command.list()
            return
        }
        try await command.join(name)
    }
}
