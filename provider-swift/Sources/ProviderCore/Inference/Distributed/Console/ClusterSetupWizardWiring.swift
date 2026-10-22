import Foundation

/// The setup wizard's honesty contract, as `ClusterConsoleWiring` is the
/// console's: every line that states something names one of these rows of
/// `handoff/TUI-wiring.md`, and every key names its own. A row is wired in
/// the table when at least one of the two screens runs or reads its real
/// operation; a check holds both screens' lines and keys to their own lists.
public enum ClusterSetupWizardWiring {
    /// Elements the wizard shows from a real operation, or runs.
    public static let wired: [String] = [
        "mac.profile", "mac.disk", "mac.version",
        "link.rdma", "link.port", "link.isolation", "link.thunderbolt", "link.fix",
        "pair.saved", "pair.verify", "pair.code", "pair.confirm", "pair.link", "pair.inbox", "pair.approve", "peer.report",
        "model.inventory", "model.plan", "model.adopt",
        "check.run",
        "session.start", "session.stop", "session.process", "session.status", "session.cleanup",
        "host.request", "journal.state",
    ]

    /// Persisted intent the wizard reads back when it opens, with the wired element that shows it.
    public static let reconciledAtLaunch: [(id: String, shownBy: String)] = [
        ("intent.wizard", "pair.confirm"), ("intent.setup", "pair.saved"),
    ]

    /// The keys and what each runs, by wired row.
    public static let keys: [(key: String, step: ClusterSetupStep, wiring: String)] = [
        ("f", .cable, "link.fix"), ("y", .cable, "link.fix"),
        ("p", .pair, "pair.verify"), ("enter", .pair, "pair.confirm"), ("l", .pair, "pair.link"), ("c", .pair, "pair.link"),
        ("enter", .model, "model.adopt"), ("a", .model, "pair.approve"),
        ("c", .check, "check.run"),
        ("s", .serve, "session.start"), ("x", .serve, "session.stop"), ("t", .serve, "host.request"),
    ]

    /// What the wizard does not do, with the reason its help gives.
    public static let unavailable: [ClusterConsoleWiring.Unavailable] = [
        .init(id: "pair.discovery", title: "Find the other Mac by itself", exists: false,
              reason: "The other Mac is known from a pair description given once, or from the setup the leader sends."),
        .init(id: "link.autostart", title: "Start when the cable is plugged in", exists: false,
              reason: "Nothing watches for a cable while this command is not running."),
        .init(id: "link.remove", title: "Undo the link fix", exists: true,
              reason: "`darkbloom cluster link --remove` does it, after its own macOS prompt."),
        .init(id: "session.percent", title: "Load progress as a percentage", exists: false,
              reason: "A worker reports ready and nothing before it; the screen counts ranks ready instead."),
        .init(id: "pair.revoke", title: "Remove a saved setup", exists: false,
              reason: "No command clears the saved cluster reference."),
        .init(id: "model.weights", title: "Verify weight files before a start", exists: false,
              reason: "Only the worker hashes weights, while loading them; the check's load is that proof."),
        .init(id: "intent.desired", title: "Restart serving after a reboot", exists: false,
              reason: "Nothing records that serving should be running; start it here again."),
    ]
}
