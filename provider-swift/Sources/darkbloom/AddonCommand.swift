import ArgumentParser
import Foundation
import ProviderCore

/// Operator debug control of add-on holds on the running provider.
struct Addon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "addon",
        abstract: "Inspect or override add-on holds on the running provider (debugging).",
        discussion: "A local add-on such as the Darkbloom Sandbox holds the provider while its VMs run: the provider stays connected to the coordinator but takes no inference and unloads its models. These commands reach the running provider through its owner-only lifecycle mailbox; add-ons themselves use the local socket.",
        subcommands: [Status.self, Hold.self, Release.self],
        defaultSubcommand: Status.self)

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show active add-on holds and whether the machine lock is held.")

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            Addon.render(try await Addon.send(.status))
        }
    }

    struct Hold: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hold the provider as the operator, exactly as an add-on would.",
            discussion: "Admission closes at once, accepted requests finish (up to two minutes), then every model unloads. Running the command again renews the lease. The hold ends when released or when its lease expires while no add-on holds the machine lock.")

        @Option(help: "Lease in seconds (30...600).")
        var leaseSeconds: Int = 600

        mutating func validate() throws {
            guard (30...600).contains(leaseSeconds) else {
                throw ValidationError("--lease-seconds must be between 30 and 600")
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let status = try await Addon.send(.hold, leaseSeconds: leaseSeconds)
            if status.failure == .unavailable {
                throw ValidationError("The provider is stopping or switching models; no hold was placed.")
            }
            Addon.render(status)
        }
    }

    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Release every active hold and return the provider to serving at once.")

        @Flag(help: "Release even while an add-on holds the machine lock (its VMs may still be using memory).")
        var force = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let status = try await Addon.send(.release, force: force)
            if status.failure == .machineLockHeld {
                throw ValidationError("An add-on holds the machine lock, so its VMs may still be running; nothing was released. Pass --force to release anyway.")
            }
            Addon.render(status)
        }
    }

    /// One mailbox round trip to the live provider, bound to its process
    /// identity so a stale request can never reach a replacement process.
    static func send(_ action: AddonHoldControlRequest.Action, leaseSeconds: Int? = nil,
                     force: Bool = false) async throws -> AddonHoldControlStatus {
        let identity = try liveIdentity(DaemonStateFile.read())
        let request = AddonHoldControlRequest(target: identity, action: action, leaseSeconds: leaseSeconds, force: force)
        let mailbox = LifecycleMailbox(identity: identity)
        try mailbox.writeAddonRequest(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard identity.isCurrent() else {
                throw ValidationError("The provider exited before answering; the outcome is unknown.")
            }
            if let status = mailbox.readAddonStatus(), status.requestID == request.id { return status }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ValidationError("The provider did not answer within 10 seconds; the outcome is unknown.")
    }

    static func liveIdentity(
        _ state: DaemonState?, now: Double = Date().timeIntervalSince1970,
        isCurrent: (ProcessIdentity) -> Bool = { $0.isCurrent() }
    ) throws -> ProcessIdentity {
        guard let state, let identity = state.processIdentity, identity.pid == state.pid,
              isCurrent(identity), !state.isStale(now: now) else {
            throw ValidationError("No running provider found. Start it with `\(BuildEnvironment.current.cliName) start`.")
        }
        guard state.addonHold != nil else {
            throw ValidationError("The running provider does not serve add-on holds. Upgrade it; standalone --local servers do not support add-ons.")
        }
        return identity
    }

    static func render(_ status: AddonHoldControlStatus, now: Date = Date()) {
        print(lines(status, now: now).joined(separator: "\n"))
    }

    static func lines(_ status: AddonHoldControlStatus, now: Date) -> [String] {
        var lines = status.holds.isEmpty
            ? ["Add-on holds: none; the provider serves normally."]
            : ["Add-on holds:"] + status.holds.map { "  " + Self.describe($0, now: now) }
        lines.append("Machine lock: \(status.machineLockHeld ? "held (add-on VMs may be running)" : "free")")
        return lines
    }

    static func describe(_ hold: AddonHoldView, now: Date) -> String {
        let since = Date(timeIntervalSince1970: Double(hold.sinceMs) / 1_000)
        let remaining = Int((Double(hold.leaseExpiresAtMs) / 1_000 - now.timeIntervalSince1970).rounded(.up))
        let lease = remaining > 0 ? "lease expires in \(remaining)s" : "lease expired (kept while the machine lock is held)"
        return "\(hold.addon): \(hold.state) since \(ISO8601DateFormatter().string(from: since)); \(lease)"
    }
}
