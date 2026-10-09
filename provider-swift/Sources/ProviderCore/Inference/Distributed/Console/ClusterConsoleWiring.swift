import Foundation

/// The console's honesty contract in code: which elements run or read a real
/// operation, and which the gate names but this build cannot do. The same
/// identifiers are the rows of `handoff/TUI-wiring.md`. Every line of the
/// screen that states something names the row it was read from
/// (`ClusterConsoleLine.Source`), and every action names its own; checks hold
/// those names to the wired list and the wired list to the table.
public enum ClusterConsoleWiring {
    /// Elements the screen shows from a real operation.
    public static let wired: [String] = [
        "link.rdma", "link.port", "link.narration", "link.wait", "link.fix", "link.alias", "doctor.checks",
        "installed.worker", "journal.state",
        "pair.saved", "pair.hostkey", "pair.identity", "pair.approval", "pair.approve",
        "model.admitted", "model.saved", "model.ranks", "model.holdings", "model.metadata", "model.files", "model.admission",
        "session.start", "session.stop", "session.process", "session.status", "session.recover",
        "host.local", "export.diagnostics",
    ]

    /// Operator intent that is persisted and read back when the screen
    /// opens, with the wired element that shows it. Nothing else is
    /// remembered between two screens.
    public static let reconciledAtLaunch: [(id: String, shownBy: String)] = [
        ("intent.setup", "pair.saved"), ("intent.alias", "link.alias"), ("intent.journal", "journal.state"),
        ("intent.running", "session.status"),
    ]

    /// Something the gate names that the screen cannot do, with the reason it
    /// shows instead. `exists` tells an operation the tree has but the screen
    /// cannot reach from one the tree does not have at all.
    public struct Unavailable: Sendable, Equatable {
        public let id: String
        public let title: String
        public let exists: Bool
        public let reason: String
    }

    public static let unavailable: [Unavailable] = [
        .init(id: "link.peer", title: "Which Mac is on the cable", exists: false,
              reason: "The link inspection reads this Mac only and contacts no peer."),
        .init(id: "link.autostart", title: "Start when the cable is plugged in", exists: false,
              reason: "Nothing watches for a cable before this command is run."),
        .init(id: "link.physical", title: "Link speed and a physical transfer check", exists: true,
              reason: "The transfer check is a separate build of the worker package, not an installed command."),
        .init(id: "link.remove", title: "Remove the port's address and its system job", exists: true,
              reason: "`darkbloom cluster link --remove` does it, after its own macOS prompt; this screen has no key for it."),
        .init(id: "pair.discovery", title: "Find a peer", exists: false,
              reason: "A peer is known only from a setup you pass in; nothing discovers one."),
        .init(id: "pair.verify", title: "Prove the peer holds its pinned key", exists: false,
              reason: "No check connects to the peer before a start."),
        .init(id: "pair.revoke", title: "Remove a saved setup", exists: false,
              reason: "No command clears the saved cluster reference."),
        .init(id: "model.weights", title: "Verify weight files", exists: false,
              reason: "Only the worker hashes weights, and only while loading them."),
        .init(id: "model.preadmission", title: "Admission before a start", exists: false,
              reason: "A worker admits when it loads; it has no admission-only mode."),
        .init(id: "model.servable", title: "Whether a start would serve the saved model on this Mac", exists: true,
              reason: "Only `darkbloom start --local --distributed` applies the model's chip and runtime requirements; its refusal is shown as it prints it."),
        .init(id: "model.plan", title: "Choose which Mac leads and where the model is cut, from what each Mac detects", exists: true,
              reason: "`darkbloom cluster plan` does it and writes a setup for each Mac; this screen has no key for it. Open the screen with the setup it wrote for this Mac and approve it with `a`."),
        .init(id: "model.picker", title: "Choose among local models", exists: true,
              reason: "Nothing lists local distributed models; another model is another setup, approved with `a`."),
        .init(id: "session.percent", title: "Load progress as a percentage", exists: false,
              reason: "A worker reports ready and nothing before it."),
        .init(id: "session.stopOther", title: "Stop a session another process started", exists: false,
              reason: "No command reaches another process's session; stop it where it was started."),
        .init(id: "session.join", title: "Join", exists: true,
              reason: "A member in this build declines every pairing the coordinator offers, so joining cannot serve."),
        .init(id: "session.leave", title: "Leave", exists: false, reason: "No leave command exists."),
        .init(id: "session.drain", title: "Drain", exists: true,
              reason: "The running leader can drain, but no command or control reaches it."),
        .init(id: "session.follower", title: "Follower live status", exists: false,
              reason: "A follower exposes no status; the leader reports both ranks."),
        .init(id: "host.coordinator", title: "Serving through the coordinator", exists: true,
              reason: "A member in this build declines every pairing the coordinator offers."),
        .init(id: "host.ownerViews", title: "Coordinator's view of your pairs", exists: true,
              reason: "The coordinator shows it to a signed-in account only; this command holds a device token."),
        .init(id: "host.request", title: "Send a test request", exists: true,
              reason: "The local endpoint accepts requests, but this command has no client for it."),
        .init(id: "observe.requests", title: "Request speed", exists: true,
              reason: "Each request's timing is logged, and nothing reads it back."),
        .init(id: "intent.desired", title: "Restart a session that should be running", exists: false,
              reason: "Nothing records that a session should be running, so this screen never starts one by itself."),
    ]
}
