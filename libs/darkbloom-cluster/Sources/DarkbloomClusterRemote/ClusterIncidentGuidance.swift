import Foundation

// Turns cluster failures into something a person can act on (PROD-PLAN S24).
//
// Ported from the design of the owner's oMLX `omlx/cluster/guidance.py`
// (Apache-2.0, multi-contributor upstream code; the stable machine codes are
// the maintainer's): an accurate but unreadable error maps to a title, a plain
// explanation and concrete next steps, and to a stable `code` that incidents
// record next to the redacted message so failures that reach the same advice
// group together. The oMLX codes are kept where the failure is the same
// (`host_key_unknown`, `login_rejected`, `peer_unreachable`, `peer_timeout`,
// `model_stage_incomplete`, `plan_changed`, `version_mismatch`, ...). Darkbloom
// adds the failures its own launches produce (wired memory a dead rank left,
// the device journal, the collective progress guard, the link control
// follower, the native bootstrap) and a classified `reason` for every failure.
//
// Pure string handling: no I/O, testable, cheap.

/// Why a cluster launch or session failed, as a stable machine code.
public enum ClusterFailureReason: String, Codable, Sendable, CaseIterable {
    case orphanedWiredMemory = "orphaned_wired_memory"
    case deviceBusy = "device_busy"
    case localProviderRunning = "local_provider_running"
    case memoryGateRefused = "memory_gate_refused"
    case followerNotConnected = "follower_not_connected"
    case localNetworkDenied = "local_network_denied"
    case sshTrust = "ssh_trust"
    case addressUnusable = "address_unusable"
    case peerUnreachable = "peer_unreachable"
    case bootstrapStalled = "bootstrap_stalled"
    case linkNotReady = "link_not_ready"
    case rdmaCompletionError = "rdma_completion_error"
    case collectiveStall = "collective_stall"
    case rankLeaseExpired = "rank_lease_expired"
    case workerRuntimeMismatch = "worker_runtime_mismatch"
    case versionMismatch = "version_mismatch"
    case modelIdentityMismatch = "model_identity_mismatch"
    case modelMissing = "model_missing"
    case planChanged = "plan_changed"
    case unsupportedMode = "unsupported_mode"
    case peerLost = "peer_lost"
    case workerCrashed = "worker_crashed"
    case startupTimedOut = "startup_timed_out"
    case launchInterrupted = "launch_interrupted"
    case configurationInvalid = "configuration_invalid"
    case cleanupUnresolved = "cleanup_unresolved"
    case modelBusy = "model_busy"
    case listenerFailed = "listener_failed"
    case requestFailed = "request_failed"
    case runtimeError = "runtime_error"
    case unclassified = "unclassified"

    /// A reason that says little by itself; a more specific one found in the
    /// diagnostics replaces it.
    var isGeneric: Bool {
        [.startupTimedOut, .peerLost, .workerCrashed, .configurationInvalid, .launchInterrupted, .unclassified].contains(self)
    }
}

/// A readable failure with the steps that resolve it.
public struct ClusterGuidance: Codable, Sendable, Equatable {
    /// Stable machine key, recorded with every incident.
    public let code: String
    public let title: String
    public let explanation: String
    public let steps: [String]
    /// One safe command that helps, when there is one.
    public let command: String?

    public init(code: String, title: String, explanation: String, steps: [String], command: String? = nil) {
        self.code = code; self.title = title; self.explanation = explanation; self.steps = steps; self.command = command
    }
}

/// A classified failure: reason, guidance, and the message to record.
public struct ClusterFailureExplanation: Sendable, Equatable {
    public let reason: ClusterFailureReason
    public let guidance: ClusterGuidance
    /// The error text the classification read (bounded, not yet redacted).
    public let message: String
    /// Which rule matched (for tests and for whoever reads the incident).
    public let rule: String?
}

public enum ClusterFailureClassifier {
    /// What a caller knows about one failure. Only `error` is required; the
    /// diagnostics are the bounded standard-error tails of the owners and
    /// workers involved, which often name the cause the error itself does not.
    public struct Context: Sendable {
        public var error: String
        public var diagnostics: [String]
        public init(error: String, diagnostics: [String] = []) { self.error = error; self.diagnostics = diagnostics }
    }

    static let maximumScannedBytes = 16 * 1024

    /// Never fails and never returns nothing: an unmatched failure is
    /// `unclassified` with generic but useful guidance.
    public static func classify(_ context: Context) -> ClusterFailureExplanation {
        let error = String(context.error.prefix(maximumScannedBytes))
        let primary = match(error)
        let message = String(error.prefix(ClusterIncidentLog.maximumMessageBytes * 2))
        if let primary, !primary.reason.isGeneric {
            return .init(reason: primary.reason, guidance: primary.guidance, message: message, rule: primary.name)
        }
        // The error itself is generic: the first specific cause in the
        // diagnostics wins (newest tail last, so scan in reverse).
        for tail in context.diagnostics.reversed() {
            let text = String(tail.suffix(maximumScannedBytes))
            if let found = match(text), !found.reason.isGeneric {
                let detail = Self.line(in: text, matching: found)
                return .init(reason: found.reason, guidance: found.guidance,
                             message: detail.map { message + " | " + $0 } ?? message, rule: found.name)
            }
        }
        if let primary { return .init(reason: primary.reason, guidance: primary.guidance, message: message, rule: primary.name) }
        // Nothing specific anywhere: a generic cause the diagnostics name still beats none.
        for tail in context.diagnostics.reversed() {
            let text = String(tail.suffix(maximumScannedBytes))
            if let found = match(text) {
                let detail = Self.line(in: text, matching: found)
                return .init(reason: found.reason, guidance: found.guidance,
                             message: detail.map { message + " | " + $0 } ?? message, rule: found.name)
            }
        }
        return .init(reason: .unclassified, guidance: ClusterGuidance.fallback, message: message, rule: nil)
    }

    public static func classify(message: String) -> ClusterFailureExplanation { classify(Context(error: message)) }

    struct Rule: Sendable {
        let name: String
        let pattern: String
        let reason: ClusterFailureReason
        /// The guidance code when it differs from the reason's own guidance.
        let guidanceCode: String?
        init(_ name: String, _ pattern: String, _ reason: ClusterFailureReason, guidance: String? = nil) {
            self.name = name; self.pattern = pattern; self.reason = reason; guidanceCode = guidance
        }
    }

    struct Match { let name: String; let reason: ClusterFailureReason; let guidance: ClusterGuidance; let pattern: String }

    /// Ordered: the first rule that matches wins, so specific precedes general.
    static let rules: [Rule] = [
        Rule("orphan-wired", #"darkbloom-orphan-wired-v1 role=\S+ decision=refused|memory is wired on this mac and no other darkbloom process|memory an earlier run left wired"#, .orphanedWiredMemory),
        Rule("journal", #"unresolved native ownership journal|lease journal is no longer empty|native ownership journal appeared|its device journal is retained|device (?:exclusion|lease|scope) (?:is )?(?:held|busy|taken)"#, .deviceBusy),
        Rule("provider-instance", #"provider instance lock|ordinary provider (?:is )?running|another darkbloom provider"#, .localProviderRunning),
        Rule("memory-gate", #"exceeds the allocator limit|load gate|memory gate|admissible memory|refuses swap in use|under memory pressure|local model slice would exceed the host memory|load-peak guard|not enough (?:free )?memory|wired limit"#, .memoryGateRefused),
        Rule("follower-link", #"follower member did not connect|follower (?:did not|never) connect|is `?darkbloom cluster link-follower`? running|no peer for its edge"#, .followerNotConnected),
        Rule("local-network", #"local network (?:access|permission|privacy)|ehostunreach.*(?:detached|local network)"#, .localNetworkDenied),
        Rule("ssh-host-unknown", #"no (?:ed25519|ecdsa|rsa|dsa) host key is known|host key for .* is not known"#, .sshTrust, guidance: "host_key_unknown"),
        Rule("ssh-host-changed", #"remote host identification has changed|offending .* host key|host key verification failed"#, .sshTrust, guidance: "host_identity_changed"),
        Rule("ssh-no-matching-key", #"no matching host key"#, .sshTrust, guidance: "no_matching_host_key"),
        Rule("ssh-login", #"permission denied \(publickey|permission denied, please try again|too many authentication failures"#, .sshTrust, guidance: "login_rejected"),
        Rule("address", #"could not resolve|nodename nor servname|name or service not known|address is not ipv4|not an ipv4 address|link-local scoped address|invalid ipv6|no interface carries ipv4"#, .addressUnusable),
        Rule("unreachable", #"connection refused|no route to host|network is unreachable|host is down|econnrefused|ehostunreach|enetunreach"#, .peerUnreachable),
        Rule("bootstrap", #"native key relay deadline expired|bootstrap (?:deadline|round|exchange)s? (?:expired|timed out|stalled)|readiness precedes authenticated bootstrap|syn_sent|mesh rounds? (?:timed out|did not)|prelude (?:timed out|deadline)"#, .bootstrapStalled),
        Rule("rdma-matrix", #"full rdma connectivity matrix|rdma (?:device|port) .*(?:down|missing|not found|unavailable)|no rdma device|link (?:is )?not ready|ibv_open_device|rdma is (?:off|disabled)"#, .linkNotReady),
        Rule("rdma-completion", #"work completion error|\[jaccl\][^\n]*status=\d"#, .rdmaCompletionError),
        Rule("collective-guard", #"collective progress (?:guard|limit)|no-progress stall|no progress for|collective_stall|progress guard (?:fired|expired)|guard exit|exit(?:ed)? (?:with )?(?:status |code )?75\b|termination=exited\(75\)"#, .collectiveStall),
        Rule("rank-lease", #"rank lease (?:lapsed|expired)|lease renewal refused|lease (?:expired|lapsed)"#, .rankLeaseExpired),
        Rule("request-failed", #"darkbloom-worker-fail-v1|failed on the pair:|rank [01] (?:reported failure|became unavailable)|worker request failed"#, .requestFailed),
        Rule("runtime-mismatch", #"executable bytes differ from the expected binary|runtime description differs from the saved capability|installed worker changed while|has no collective progress guard|worker policy or device geometry differs|native launch differs from installed owner binding|importerror"#, .workerRuntimeMismatch),
        Rule("version", #"unsupported worker protocol version|protocol version|versions? (?:do not match|mismatch|differ)|python local=\S+ remote="#, .versionMismatch),
        Rule("model-identity", #"model identity differs|resident identity differs|checkpoint aggregate mismatch|checkpoint manifest differs|artifact (?:sha-?256 )?differs|installed input identity or sha-256 differs"#, .modelIdentityMismatch),
        Rule("model-missing", #"weight file is missing|model stage is incomplete|missing [^\n]*\.safetensors|model (?:directory|folder) [^\n]*(?:missing|not found)|missing the model|not found on this peer|cannot open installed input"#, .modelMissing),
        Rule("plan", #"installed matrix changed|not the plan you approved|plan (?:sha-?256 )?differs|plan_mismatch|budgets, roles or layer split changed|leader opened another plan|did not activate the approved plan|differs from this member's (?:cluster or rank|selection)|committed native start differs|native start without its profile|admission epoch differs"#, .planChanged),
        Rule("busy", #"while a request is (?:being )?served|model is busy|topology change refused|follower is serving another session"#, .modelBusy),
        Rule("listener", #"bindfailed|address already in use|eaddrinuse|listener stopped during startup"#, .listenerFailed),
        Rule("unsupported", #"does not advertise|is not supported|not supported for distributed|no speculative decoding on a pair|cannot shard this model|unsupported generation mode"#, .unsupportedMode),
        Rule("cleanup", #"cleanup is unresolved|ownership cannot be resolved|outlived its own deadline and every signal|remote (?:rank )?kill failed|terminate\(\) (?:threw|failed)"#, .cleanupUnresolved),
        Rule("runtime-error", #"there is no stream\(|valueerror|typeerror|runtimeerror|materializer unavailable|fatal error|uncaught exception|scalar conversion"#, .runtimeError),
        Rule("peer-lost", #"peer[ _](?:lost|failure|exited|closed)|peerfailure|rank \d (?:exited|ended|was lost)|worker exited while|lost (?:its|the) peer|connection reset|broken pipe|remote protocol error|ssh (?:exited|closed)"#, .peerLost),
        Rule("worker-crash", #"signalled|terminated by signal|exited with (?:status|code)|launcher terminated|worker failed"#, .workerCrashed),
        Rule("startup-timeout", #"startup exhausted its deadline|did not establish bilateral readiness|startup deadline|preflight deadline expired|metadata deadline expired|timed out|timeout|deadline expired|bindtimedout"#, .startupTimedOut),
        Rule("interrupted", #"startupinterrupted|shuttingdown|cancellationerror|interrupted|follower is stopping"#, .launchInterrupted),
        Rule("configuration", #"saved setup|clusterconfigurationerror|configuration"#, .configurationInvalid),
    ]

    private static let compiled: [(Rule, NSRegularExpression)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])).map { (rule, $0) }
    }

    static func match(_ text: String) -> Match? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (rule, expression) in compiled where expression.firstMatch(in: text, range: range) != nil {
            let guidance = rule.guidanceCode.flatMap(ClusterGuidance.guidance(code:)) ?? ClusterGuidance.guidance(for: rule.reason)
            return .init(name: rule.name, reason: rule.reason, guidance: guidance, pattern: rule.pattern)
        }
        return nil
    }

    /// The diagnostic line that matched, bounded, so the incident shows it.
    static func line(in text: String, matching found: Match) -> String? {
        guard let expression = try? NSRegularExpression(pattern: found.pattern, options: [.caseInsensitive]) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line)
            if expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                return String(value.prefix(240))
            }
        }
        return nil
    }
}

extension ClusterGuidance {
    /// The guidance a reason maps to. Every reason has one.
    public static func guidance(for reason: ClusterFailureReason) -> ClusterGuidance {
        table[reason] ?? fallback
    }

    /// The guidance with this code, including the SSH sub-codes.
    public static func guidance(code: String) -> ClusterGuidance? {
        if let value = table.values.first(where: { $0.code == code }) { return value }
        return ssh[code] ?? (code == fallback.code ? fallback : nil)
    }

    /// The oMLX entry point: guidance for one error message. Never nil.
    public static func explain(_ message: String?) -> ClusterGuidance {
        guard let message, !message.isEmpty else { return fallback }
        return ClusterFailureClassifier.classify(message: message).guidance
    }

    public static let fallback = ClusterGuidance(code: "unknown_failure",
        title: "Something went wrong with the cluster",
        explanation: "The step did not complete. The technical detail is recorded with this incident.",
        steps: ["Retry: a first connection over a new link is often slower.",
                "If it repeats, run `darkbloom cluster doctor` on both Macs and compare what it reports."],
        command: "darkbloom cluster doctor")

    /// SSH only exists in the developer test harness: the product pairs with `darkbloom cluster` and never asks a
    /// user for SSH, so every SSH guidance leads with the product path.
    static let devHarness = ["Run `darkbloom cluster` on both Macs to pair them again; no SSH is needed."]
    static let ssh: [String: ClusterGuidance] = [
        "host_key_unknown": .init(code: "host_key_unknown", title: "The other Mac isn't trusted yet",
            explanation: "SSH stopped before login because this Mac has not recorded the other Mac's host key.",
            steps: devHarness + ["Run the cluster setup again and confirm the other Mac's fingerprint."]),
        "host_identity_changed": .init(code: "host_identity_changed", title: "The other Mac's saved identity changed",
            explanation: "SSH refused the connection because this address now presents a different key.",
            steps: devHarness + ["Confirm the address still belongs to the expected Mac, then pair again."]),
        "no_matching_host_key": .init(code: "no_matching_host_key", title: "The Macs could not agree on an SSH host key",
            explanation: "The other Mac is reachable, but its SSH server offered no host-key algorithm this Mac accepts.",
            steps: devHarness + ["Update both Macs to a current macOS release and pair again."]),
        "login_rejected": .init(code: "login_rejected", title: "The other Mac rejected the login",
            explanation: "SSH connected but the other Mac would not accept this Mac's key.",
            steps: devHarness + ["Check the user name in the developer harness's saved setup."]),
    ]

    static let table: [ClusterFailureReason: ClusterGuidance] = [
        .orphanedWiredMemory: .init(code: "orphaned_wired_memory", title: "Memory is still wired from an earlier run",
            explanation: "A rank that ended without releasing its memory left it wired with no process that owns it. A new rank is refused rather than admitted against memory the Mac does not have.",
            steps: ["Restart the Mac named in the incident: only a restart returns that memory.",
                    "Then start again; nothing else needs to change."]),
        .deviceBusy: .init(code: "device_busy", title: "An earlier session still holds this Mac's cluster device",
            explanation: "The device journal names an owner or worker from an earlier session that was not seen to exit.",
            steps: ["Run `darkbloom cluster recover` on that Mac; it clears the journal once nothing it names is running.",
                    "If a worker is still running, stop it with SIGTERM and wait for it to exit."],
            command: "darkbloom cluster recover"),
        .localProviderRunning: .init(code: "local_provider_running", title: "An ordinary provider is running on this Mac",
            explanation: "A single-Mac provider uses the same GPU and memory, so a cluster rank refuses to start beside it.",
            steps: ["Stop the other provider (`darkbloom stop`), then start the cluster again."], command: "darkbloom stop"),
        .memoryGateRefused: .init(code: "memory_gate_refused", title: "A Mac did not have room for its share of the model",
            explanation: "The load gate measured the memory free now and refused the stage before loading it, so nothing was half-loaded.",
            steps: ["Quit large applications on the Mac named in the incident and retry.",
                    "Ask the planner for a new split from both Macs' memory now (the console's plan step).",
                    "Choose a shorter context or a smaller model if it still does not fit."]),
        .followerNotConnected: .init(code: "follower_not_connected", title: "The other Mac's member is not connected",
            explanation: "The leader listens on the link control channel and the other Mac's member never dialled in, so its rank could not be opened.",
            steps: ["Check that Darkbloom is running on the other Mac as a cluster member.",
                    "Run `darkbloom cluster link` on both Macs: the cable must be up and the link ready.",
                    "If the other Mac's member logs EHOSTUNREACH, approve Local Network access for Darkbloom on that Mac once."]),
        .localNetworkDenied: .init(code: "local_network_denied", title: "macOS blocked Darkbloom from the local network",
            explanation: "macOS asks once per app before it may reach other devices on the local network; until it is approved every dial fails.",
            steps: ["On the Mac named in the incident, open System Settings > Privacy & Security > Local Network and allow Darkbloom.",
                    "This is approved once and survives restarts; record it if it is asked again."]),
        .sshTrust: ssh["login_rejected"]!,
        .addressUnusable: .init(code: "address_unresolved", title: "A cluster address cannot be used",
            explanation: "An address in the setup could not be parsed or is not on the link interface.",
            steps: ["Run `darkbloom cluster link` on both Macs: the cable must be up and the link ready.",
                    "Run `darkbloom cluster` on both Macs to pair them again; it uses the addresses macOS gives the cable by itself, so no network settings are needed."],
            command: "darkbloom cluster link"),
        .peerUnreachable: .init(code: "peer_unreachable", title: "Can't reach the other Mac",
            explanation: "The address resolved but nothing answered on the link.",
            steps: ["Check the other Mac is awake: a sleeping Mac drops the link.",
                    "Reseat the Thunderbolt cable and run `darkbloom cluster link` on both Macs.",
                    "If the link is ready but every dial says no route to host, approve Local Network access for Darkbloom on the dialling Mac."],
            command: "darkbloom cluster link"),
        .bootstrapStalled: .init(code: "bootstrap_stalled", title: "The two ranks could not finish finding each other",
            explanation: "The native bootstrap exchange between the ranks did not complete in time; on Thunderbolt this is the stuck-connection failure the owner's oMLX also saw.",
            steps: ["Retry once: the exchange is restarted from scratch.",
                    "If it repeats, run `darkbloom cluster link` on both Macs and check both link addresses."]),
        .linkNotReady: .init(code: "link_not_ready", title: "The RDMA link between the Macs is not ready",
            explanation: "A rank could not open its RDMA device or the full connectivity matrix between the Macs.",
            steps: ["Run `darkbloom cluster link` on both Macs and follow what it reports.",
                    "RDMA over Thunderbolt is turned on only from macOS Recovery (`rdma_ctl enable`); Darkbloom never changes it."],
            command: "darkbloom cluster link"),
        .rdmaCompletionError: .init(code: "rdma_completion_error", title: "The RDMA link lost a transfer",
            explanation: "The RDMA driver reported a failed work completion; the ranks stopped instead of waiting forever.",
            steps: ["Retry: the session is started fresh.", "If it repeats, reseat the cable and check `darkbloom cluster link` on both Macs."]),
        .collectiveStall: .init(code: "collective_stall", title: "A rank stopped making progress",
            explanation: "The collective progress guard ended a rank that waited too long on its peer (exit 75), releasing its memory first.",
            steps: ["Check the other Mac is awake and its rank is running.", "Retry; if it repeats under load, note the time and the model for the operator."]),
        .rankLeaseExpired: .init(code: "rank_lease_expired", title: "The leader stopped renewing a rank's lease",
            explanation: "A rank that no longer hears from its leader ends itself so it cannot hold memory forever.",
            steps: ["Check the leader Mac is running and the link is up.", "The next start forms a fresh session; nothing needs to be cleaned up."]),
        .workerRuntimeMismatch: .init(code: "worker_runtime_unverified", title: "The worker on one Mac is not the one the setup names",
            explanation: "The installed worker's bytes, policy or runtime description differ from the saved setup, so its rank was not started.",
            steps: ["Install the same Darkbloom build on both Macs.", "Run `darkbloom cluster` again; it sets the cluster up again by itself."]),
        .versionMismatch: .init(code: "version_mismatch", title: "The two Macs are running different versions",
            explanation: "Ranks must run identical Darkbloom and MLX builds; a mismatch gives wrong results rather than a clean error.",
            steps: ["Update both Macs to the same Darkbloom release.", "Run `darkbloom cluster doctor` on both afterwards."]),
        .modelIdentityMismatch: .init(code: "model_identity_mismatch", title: "The two Macs hold different copies of the model",
            explanation: "A rank found model files whose identity differs from the setup's pinned artifact.",
            steps: ["Download the model again on the Mac named in the incident so both hold the catalog's artifact."]),
        .modelMissing: .init(code: "model_stage_incomplete", title: "A model shard still needs preparing",
            explanation: "One Mac does not have a file its assigned layers need, so the cluster stayed stopped.",
            steps: ["Download the same model on the Mac named in the incident.", "Then start again; only the missing files are needed."]),
        .planChanged: .init(code: "plan_changed", title: "The cluster plan changed before launch",
            explanation: "The placement about to launch differed from the one that was checked and approved, so nothing was started.",
            steps: ["Retry: a fresh plan is derived from both Macs' memory now.", "If it repeats, run `darkbloom cluster` and choose the model again."]),
        .unsupportedMode: .init(code: "unsupported_mode", title: "This model can't run in that mode on the pair",
            explanation: "The worker does not advertise the selected generation mode for this model.",
            steps: ["Run `darkbloom cluster` and choose the model again; the planner picks a mode the worker supports."]),
        .peerLost: .init(code: "peer_lost", title: "The other Mac's rank went away",
            explanation: "The rank on the other Mac ended or its connection closed while the session needed it.",
            steps: ["Check the other Mac is awake and Darkbloom is running there.", "Retry; the session is formed again from scratch."]),
        .workerCrashed: .init(code: "worker_crashed", title: "A rank's process ended unexpectedly",
            explanation: "A worker ended on a signal or a non-zero status during the launch or while serving.",
            steps: ["Retry once.", "If it repeats, keep the incident and the worker's log for the operator."]),
        .startupTimedOut: .init(code: "peer_timeout", title: "The pair did not become ready in time",
            explanation: "Both ranks were started but did not report readiness before the startup allowance ran out.",
            steps: ["Check neither Mac is asleep or under heavy load.", "Retry: a first load after a restart reads the model from disk and is slower."]),
        .launchInterrupted: .init(code: "launch_interrupted", title: "The launch was stopped before it finished",
            explanation: "A stop arrived while the pair was still starting.",
            steps: ["Start again when ready; nothing is left running."]),
        .configurationInvalid: .init(code: "configuration_invalid", title: "The saved cluster setup could not be used",
            explanation: "The saved setup or one of its pinned files failed verification.",
            steps: ["Run `darkbloom cluster doctor` and follow what it reports.", "Run `darkbloom cluster` again; it sets the cluster up again by itself."],
            command: "darkbloom cluster doctor"),
        .cleanupUnresolved: .init(code: "cleanup_unresolved", title: "A stop could not prove everything was released",
            explanation: "An owner did not confirm its worker ended and its device was released within the allowance; ownership is kept until it does.",
            steps: ["Wait a minute: each owner keeps waiting and clears its own journal when its worker exits.",
                    "Then run `darkbloom cluster recover` on both Macs to see what is left."], command: "darkbloom cluster recover"),
        .modelBusy: .init(code: "model_busy", title: "The pair was busy serving a request",
            explanation: "A start or topology change was refused because a request was being served; nothing was interrupted.",
            steps: ["Retry once the request has finished, or drain the pair first."]),
        .listenerFailed: .init(code: "listener_failed", title: "The local serving port could not be opened",
            explanation: "The leader could not listen on its local API port, so the pair was stopped again.",
            steps: ["Check that no other process uses the port (`darkbloom local` shows it), or choose another with --port."]),
        .requestFailed: .init(code: "request_failed", title: "A request failed on the pair",
            explanation: "A rank could not complete a request, so the pair stopped and gave its memory back. The technical detail (the owner side's own words and the worker's last lines) is recorded with this incident.",
            steps: ["Start the pair again; it serves from scratch.", "If it repeats for one kind of request (for example sampled requests), keep the incident and the worker's log for the operator: it is a bug to fix, not a setting."]),
        .runtimeError: .init(code: "runtime_error", title: "The model runtime hit an internal error",
            explanation: "A rank's runtime raised an error of its own while loading or serving, not a link or memory failure.",
            steps: ["Retry once.", "If it repeats, keep the incident and the worker's log for the operator: it is a bug to fix, not a setting."]),
        .unclassified: fallback,
    ]
}
