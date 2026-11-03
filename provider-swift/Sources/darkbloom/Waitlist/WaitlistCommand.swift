import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom waitlist [<name> [status|join]]`: the waitlists of the
/// coordinator's catalog. Without a name it lists them; with one it shows the
/// account's place on that waitlist, or joins it.

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
    /// Joins the waitlist `feature`: with this Mac's chip and memory and
    /// `macCount` when it is set, else naming no Mac.
    var join: @Sendable (_ feature: String, _ macCount: Int?) async -> FeatureWaitlistLookup

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
            join: { feature, macCount in
                await client.join(feature, macCount.map { thisMac(macCount: $0) } ?? FeatureWaitlistRequest())
            })
    }

    private static func failing(_ coordinator: String, _ reason: String) -> FeatureWaitlistAccess {
        let problem = FeatureWaitlistProblem.unavailable(reason)
        return FeatureWaitlistAccess(coordinator: coordinator, waitlists: { .failure(problem) },
                                     place: { _ in .failure(problem) }, join: { _, _ in .failure(problem) })
    }

    /// The Mac a join names: its chip and memory, as `darkbloom doctor` reads
    /// them, and the Mac count. A Mac that cannot be read sends the count.
    private static func thisMac(macCount: Int) -> FeatureWaitlistRequest {
        let hardware = try? HardwareDetector.detect()
        return FeatureWaitlistRequest(chip: hardware?.chipName, memoryGB: hardware.map { Int($0.memoryGb) }, macCount: macCount)
    }
}

/// What `darkbloom waitlist` does: ask, then print the answer or why there
/// is none.
struct FeatureWaitlistCommand {
    let access: FeatureWaitlistAccess
    let view: FeatureWaitlistView
    let json: Bool

    /// Every waitlist and where the account stands on it.
    func list() async throws {
        let waitlists = try answer(await access.waitlists(), title: nil)
        guard json else {
            view.list(waitlists.data).forEach { print($0) }
            return
        }
        try printDocument(waitlists)
    }

    /// The account's place on the waitlist `name` names, as the list
    /// answers it.
    func status(_ name: String) async throws {
        try show(try await waitlist(named: name), name: name)
    }

    /// Joins the waitlist `name` names, naming this Mac when it asks for
    /// Macs. A revoked account is shown its state but did not join, so the
    /// command fails.
    func join(_ name: String, macs: Int?) async throws {
        let waitlist = try await waitlist(named: name)
        let macCount: Int?
        do {
            macCount = try waitlist.joinMacCount(macs)
        } catch {
            // The refusal names the waitlist by the coordinator's title.
            printError(FeatureWaitlistView.printable("\(error)"))
            throw ExitCode.validationFailure
        }
        let place = try answer(await access.join(waitlist.feature, macCount), title: waitlist.title)
        try show(place, name: name)
        if place.status == .revoked { throw ExitCode.failure }
    }

    /// The catalog's waitlist that `name` names; an unknown name says which
    /// waitlists there are.
    private func waitlist(named name: String) async throws -> FeatureWaitlistPlace {
        let waitlists = try answer(await access.waitlists(), title: nil)
        guard let waitlist = waitlists.named(name) else {
            view.unknown(name, among: waitlists.data).forEach { printError($0) }
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
            view.problem(problem, title: title).forEach { printError($0) }
            throw ExitCode.failure
        }
    }

    private func show(_ place: FeatureWaitlistPlace, name: String) throws {
        guard json else {
            view.lines(place, name: name.lowercased()).forEach { print($0) }
            return
        }
        try printDocument(place)
    }

    /// The coordinator's answer as JSON, times in ISO 8601, with no control
    /// or format character written raw.
    private func printDocument(_ document: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(FeatureWaitlistView.escapingUnprintable(json: String(decoding: try encoder.encode(document), as: UTF8.self)))
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
        abstract: "List the waitlists Darkbloom approves accounts from, join one, or see where you stand.",
        discussion: """
        Darkbloom opens some features, such as clusters and Darkbloom Sandbox, to the accounts it approves \
        from a waitlist; the coordinator lists the waitlists. Without a name, this command shows each one and \
        where your account stands. With a name, it shows your place on that waitlist, or joins it with \
        `join`. Use a Mac linked to your account (`\(BuildEnvironment.current.cliName) login`); \
        `\(BuildEnvironment.current.cliName) sandbox setup` installs nothing until Darkbloom approves the account.

        Examples:
          \(BuildEnvironment.current.cliName) waitlist
          \(BuildEnvironment.current.cliName) waitlist clusters join --macs 3
          \(BuildEnvironment.current.cliName) waitlist sandbox
        """)

    enum Action: String, CaseIterable, ExpressibleByArgument, Sendable {
        case status
        case join
    }

    @Argument(help: ArgumentHelp(
        "The waitlist's id, as the list shows it in parentheses, or its plural (such as clusters or sandbox). "
            + "Without one, lists every waitlist.",
        valueName: "name"))
    var name: String?

    @Argument(help: ArgumentHelp("status shows where you stand; join joins the waitlist.", valueName: "action"))
    var action: Action = .status

    @Option(help: ArgumentHelp(
        "How many Macs you plan to use, for a waitlist that asks. Default: the fewest it takes.", valueName: "n"))
    var macs: Int?

    @Flag(help: "Print the coordinator's answer as JSON.")
    var json = false

    @OptionGroup var configOptions: ConfigOptions

    /// The range of `--macs` comes from the coordinator, so `join` checks it
    /// once the list has answered.
    func validate() throws {
        guard let macs else { return }
        // `waitlist join --macs 3` reads `join` as the name: show the order.
        guard action == .join else {
            throw ValidationError("--macs applies only to join: \(BuildEnvironment.current.cliName) waitlist <name> join --macs <n>")
        }
        guard macs >= 1 else { throw ValidationError("--macs must be at least 1") }
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let command = FeatureWaitlistCommand(configPath: configOptions.config, json: json)
        guard let name else {
            try await command.list()
            return
        }
        switch action {
        case .status: try await command.status(name)
        case .join: try await command.join(name, macs: macs)
        }
    }
}
