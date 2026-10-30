import ArgumentParser
import Foundation
import ProviderCore

/// `darkbloom waitlist clusters` and `darkbloom waitlist sandbox`: join the
/// waitlist that Darkbloom approves accounts from, and read your place on it.

/// The two calls a command makes to a feature's waitlist. `live` asks the
/// coordinator of this Mac's provider configuration with its login token;
/// tests replace the calls.
struct FeatureWaitlistAccess: Sendable {
    /// The coordinator asked, for the lines that name it.
    var coordinator: String
    var place: @Sendable () async -> FeatureWaitlistLookup
    var join: @Sendable (_ macCount: Int) async -> FeatureWaitlistLookup

    /// The waitlist of `feature` on the coordinator of the provider
    /// configuration at `configPath`, or of the default one.
    static func live(_ feature: FeatureWaitlistFeature, configPath: String? = nil) -> FeatureWaitlistAccess {
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
            place: { await client.place(feature) },
            join: { macCount in await client.join(feature, thisMac(macCount: macCount)) })
    }

    private static func failing(_ coordinator: String, _ reason: String) -> FeatureWaitlistAccess {
        FeatureWaitlistAccess(coordinator: coordinator, place: { .unavailable(reason) }, join: { _ in .unavailable(reason) })
    }

    /// The Mac a join names: its chip and memory, as `darkbloom doctor` reads
    /// them. A Mac that cannot be read joins without them.
    private static func thisMac(macCount: Int) -> FeatureWaitlistRequest {
        let hardware = try? HardwareDetector.detect()
        return FeatureWaitlistRequest(chip: hardware?.chipName ?? "", memoryGB: Int(hardware?.memoryGb ?? 0), macCount: macCount)
    }
}

struct WaitlistCommandOptions: ParsableArguments {
    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "Print the coordinator's answer as JSON.")
    var json = false
}

/// What a waitlist command does: ask, then print the place or why there is
/// none.
struct FeatureWaitlistCommand {
    let access: FeatureWaitlistAccess
    let view: FeatureWaitlistView
    let json: Bool

    init(_ feature: FeatureWaitlistFeature, options: WaitlistCommandOptions) {
        access = .live(feature, configPath: options.configOptions.config)
        view = FeatureWaitlistView(feature: feature, cli: BuildEnvironment.current.cliName, coordinator: access.coordinator)
        json = options.json
    }

    func status() async throws {
        try show(await access.place())
    }

    /// A revoked account is shown its state but did not join, so the command
    /// fails.
    func join(macCount: Int) async throws {
        let lookup = await access.join(macCount)
        try show(lookup)
        if case .place(let place) = lookup, place.status == .revoked { throw ExitCode.failure }
    }

    private func show(_ lookup: FeatureWaitlistLookup) throws {
        guard case .place(let place) = lookup else {
            view.problem(lookup).forEach { printError($0) }
            throw ExitCode.failure
        }
        guard json else {
            view.lines(place).forEach { print($0) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(place), as: UTF8.self))
    }
}

/// `darkbloom waitlist`: the waitlists Darkbloom approves accounts from,
/// one command per feature.
struct Waitlist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Join the waitlists for clusters and Darkbloom Sandbox, or see where you stand.",
        discussion: """
        Darkbloom opens clusters and Darkbloom Sandbox to the accounts it approves from a waitlist per \
        feature. Join from a Mac linked to your account (`\(BuildEnvironment.current.cliName) login`); \
        `\(BuildEnvironment.current.cliName) sandbox setup` installs nothing until Darkbloom approves the account.
        """,
        subcommands: [Clusters.self, Sandboxes.self])

    struct Clusters: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Join the waitlist for clusters, or see your place on it.",
            discussion: "Without a subcommand, shows your place.",
            subcommands: [Join.self, Status.self])

        /// Bare `clusters` shows the place, while `--help` still shows this
        /// command's help.
        mutating func run() async throws {
            var status = try Status.parse([])
            try await status.run()
        }

        struct Join: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Join the cluster waitlist with this Mac's chip and memory.",
                discussion: "Joining again keeps your place and updates the Mac you named.")

            @Option(help: "How many Macs you plan to cluster (2-4).")
            var macs = 2

            @OptionGroup var options: WaitlistCommandOptions

            func validate() throws {
                guard (2...4).contains(macs) else { throw ValidationError("--macs must be between 2 and 4") }
            }

            mutating func run() async throws {
                Darkbloom.ensureLogging()
                try await FeatureWaitlistCommand(.cluster, options: options).join(macCount: macs)
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show your place on the cluster waitlist.")

            @OptionGroup var options: WaitlistCommandOptions

            mutating func run() async throws {
                Darkbloom.ensureLogging()
                try await FeatureWaitlistCommand(.cluster, options: options).status()
            }
        }
    }

    /// `darkbloom waitlist sandbox`; the type is plural so it does not hide
    /// the `Sandbox` command group.
    struct Sandboxes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sandbox",
            abstract: "Join the Darkbloom Sandbox waitlist, or see your place on it.",
            discussion: "Without a subcommand, shows your place.",
            subcommands: [Join.self, Status.self])

        /// Bare `sandbox` shows the place, while `--help` still shows this
        /// command's help.
        mutating func run() async throws {
            var status = try Status.parse([])
            try await status.run()
        }

        struct Join: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Join the Darkbloom Sandbox waitlist with this Mac's chip and memory.",
                discussion: "Joining again keeps your place and updates the Mac you named.")

            @OptionGroup var options: WaitlistCommandOptions

            mutating func run() async throws {
                Darkbloom.ensureLogging()
                try await FeatureWaitlistCommand(.sandbox, options: options).join(macCount: 1)
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show your place on the Darkbloom Sandbox waitlist.")

            @OptionGroup var options: WaitlistCommandOptions

            mutating func run() async throws {
                Darkbloom.ensureLogging()
                try await FeatureWaitlistCommand(.sandbox, options: options).status()
            }
        }
    }
}
