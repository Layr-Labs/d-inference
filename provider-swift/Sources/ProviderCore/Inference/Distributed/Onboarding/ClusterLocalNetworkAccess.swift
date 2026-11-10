import Foundation
import Darwin
import SystemConfiguration

/// Local Network privacy (macOS 15 and later) for the cluster: macOS asks once per program before the program may
/// reach other devices on the local network, the Thunderbolt cable included, and refuses the program's packets
/// (`EHOSTUNREACH`) until the person allows it. Left alone, each prompt appears whenever that program's first traffic
/// happens to flow, often while the person is at the other Mac (2026-11-02 onboarding review: "approve prompts for
/// network access are out of sync"). The onboarding asks at stated moments instead:
///
/// - this command probes in Connect. macOS lets command-line tools run from Terminal or over SSH through by
///   themselves (Apple's TN3179), so this asks nothing unless the probe finds the cable blocked anyway; macOS then
///   names the program it attributes the command to (the terminal app, or sshd-keygen-wrapper in an SSH session);
/// - this Mac's cluster service probes as it starts (once paired): a launchd agent is not let through by itself, so
///   macOS asks about Darkbloom then, and the service keeps each outcome in a file the onboarding reads while it
///   waits for the answer.
///
/// A probe is one datagram to the cable's subnet broadcast address, sent from the cable's interface to the discard
/// port: nothing on the other Mac reads it.
public enum ClusterLocalNetworkAccess {
    /// Whether a datagram on `interface` (the cable's) is let through now. Nil `interface`: the one Thunderbolt
    /// interface with an IPv4 address, as pairing finds it.
    public static func probe(interface: String? = nil) -> ClusterOnboardingLocalNetwork {
        guard let name = interface ?? (try? ClusterPairCommandLine.resolveInterface(ClusterPairCommandRequest(), peer: nil)),
              let target = broadcastAddress(interface: name) else { return .unknown }
        let index = if_nametoindex(name)
        guard index != 0 else { return .unknown }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return .unknown }
        defer { Darwin.close(socket) }
        var on: Int32 = 1
        var bound = index
        guard setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(socket, IPPROTO_IP, IP_BOUND_IF, &bound, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return .unknown }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr = target
        let payload = Array("darkbloom local network check".utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(socket, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent == payload.count { return .allowed }
        return blocked(errno) ? .blocked : .unknown
    }

    /// The errors macOS gives a program it has not let onto the local network.
    static func blocked(_ error: Int32) -> Bool { error == EHOSTUNREACH || error == EPERM }

    /// The interface's IPv4 broadcast address (address | ~mask), or nil when it has no IPv4 address.
    static func broadcastAddress(interface: String) -> in_addr? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard String(cString: item.ifa_name) == interface, let address = item.ifa_addr, let mask = item.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let net = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return in_addr(s_addr: host | ~net)
        }
        return nil
    }

    /// This command runs in an SSH session: macOS shows its windows on the Mac's own screen, not in this terminal.
    public static func overSSH(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["SSH_CONNECTION"] != nil || environment["SSH_TTY"] != nil
    }

    /// The app macOS names when it asks about a command run in this terminal: sshd-keygen-wrapper (the program macOS
    /// attributes an SSH session to) over SSH, else the terminal app (`TERM_PROGRAM`), else plain words.
    public static func commandApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if overSSH(environment: environment) { return "sshd-keygen-wrapper" }
        switch environment["TERM_PROGRAM"] {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "vscode": return "Visual Studio Code"
        case "WarpTerminal": return "Warp"
        case "ghostty": return "Ghostty"
        case let name? where !name.isEmpty && name.count <= 40 && ClusterOnboardingDeployment.shownPlainly(name): return name
        default: return "your terminal app"
        }
    }

    /// This Mac's name as System Settings shows it (General → About), for its own screen only: two identical Macs
    /// read the same hardware, so each says which it is. Nil when macOS gives none.
    public static func computerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    // MARK: - The cluster service's own probe

    /// What the service last saw, for the onboarding to read.
    struct Report: Codable, Equatable {
        var state: ClusterOnboardingLocalNetwork
        /// The service process that probed: a report of an earlier run never speaks for this one.
        var pid: Int32
    }

    /// How often the service probes while refused: every 2 s for the first minutes, then every 10 s for as long as it
    /// runs (the onboarding waits for the answer without a deadline, so an Allow clicked later is still seen).
    static let serviceProbeFastSeconds: Double = 300
    static let serviceProbeInterval: useconds_t = 2_000_000
    static let serviceProbeSlowInterval: useconds_t = 10_000_000

    /// The report in a service's own directory (the one its pid file is in).
    static func reportFile(in directory: URL) -> URL { directory.appendingPathComponent("local-network.json") }

    static func reportFile() -> URL? {
        (try? ClusterService.paths()).map { reportFile(in: $0.pid.deletingLastPathComponent()) }
    }

    /// The service's side, from its start: probes at once (the probe that makes macOS ask about Darkbloom), then while
    /// refused, keeping each outcome in `directory` (the service's own) for the onboarding; stops once allowed. Off the
    /// service's thread; says each change in the service log.
    static func startServiceProbe(directory: URL,
                                         probe: @escaping @Sendable () -> ClusterOnboardingLocalNetwork = { probe() },
                                         fastSeconds: Double = serviceProbeFastSeconds,
                                         intervals: (fast: useconds_t, slow: useconds_t) = (serviceProbeInterval, serviceProbeSlowInterval),
                                         say: @escaping @Sendable (String) -> Void) {
        let file = reportFile(in: directory)
        Thread.detachNewThread {
            let started = Date()
            var last: ClusterOnboardingLocalNetwork?
            while true {
                let state = probe()
                if state != last {
                    write(Report(state: state, pid: getpid()), to: file)
                    if state != .unknown { say("local network access for this service: \(state.rawValue)") }
                    last = state
                }
                if state == .allowed { return }
                usleep(Date().timeIntervalSince(started) < fastSeconds ? intervals.fast : intervals.slow)
            }
        }
    }

    static func write(_ report: Report, to file: URL) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: file, options: [.atomic])
        chmod(file.path, 0o600)
    }

    /// The service's Local Network access from its probe's `report` and its published status (`published`).
    /// The follower the service runs is the process that dials the other Mac: its refusal, which the service publishes,
    /// is blocked whatever the probe's broadcast found (pair-2's M5 Max and the M5 Ultra pair's headless Mac B: the probe
    /// logged "allowed" while macOS refused every dial). Only while that follower runs: an ended one's refusal is history.
    static func state(report: ClusterOnboardingLocalNetwork, published: ClusterServiceStatus.Child?) -> ClusterOnboardingLocalNetwork {
        published?.running == true && published?.lastError?.hasPrefix(ClusterService.localNetworkReasonPrefix) == true ? .blocked : report
    }

    /// The running service's last outcome: unknown when it wrote none yet (a service of an older build never does).
    public static func serviceState() -> ClusterOnboardingLocalNetwork {
        state(report: reportedState(), published: ClusterService.published()?.child)
    }

    static func reportedState() -> ClusterOnboardingLocalNetwork {
        guard let paths = try? ClusterService.paths(), let file = reportFile(),
              let pidText = try? String(contentsOf: paths.pid, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: file), data.count <= 4_096,
              let report = try? JSONDecoder().decode(Report.self, from: data), report.pid == pid else { return .unknown }
        return report.state
    }

    // MARK: - The cable's port, where macOS cannot show its prompt

    /// Runs Darkbloom's own link setup script (this install's `cluster-device/link-fix.sh`, written owner-only by the
    /// link setup) with sudo, attached to this terminal: sudo asks for the password itself; Darkbloom never reads it.
    /// Any other path, or a file that is not this user's private regular file, is refused. True when it exited 0.
    public static func runLinkScriptWithSudo(_ shown: String, paths: ClusterUserPaths) -> Bool {
        let home = paths.homeDirectory.path
        let path = shown.hasPrefix("~/") ? home + shown.dropFirst(1) : shown
        let expected = paths.deviceDirectory.appendingPathComponent("link-fix.sh").path
        var metadata = stat()
        guard path == expected, lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o022 == 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["/bin/sh", path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let childExit = ProcessExitObserver()
        do { try childExit.run(process) } catch { return false }
        childExit.wait()
        return process.terminationStatus == 0
    }
}

// MARK: - The status commands' view of a refusal

extension ClusterLocalNetworkAccess {
    /// Which Mac's link follower macOS keeps off the local network, so the pair can't serve until someone turns the
    /// setting on there (`statusWords`).
    public enum Refused: Sendable, Equatable {
        /// This Mac's: its cluster service's follower (`serviceState` reads `.blocked`).
        case thisMac
        /// The other Mac's, which this Mac's part waits for (`otherMacRefused`).
        case otherMac
    }

    /// On the leading Mac, whether the other Mac's part reports the refusal now (`otherMacRefused(member:own:now:)`). That
    /// Mac is asked (`otherMacStatus`) only once this Mac's part has run long enough for its answer to count; before
    /// that, asking would not tell. `acrossRestarts`: a status read, which keeps a refusal this Mac's last part already
    /// outlasted while its next part starts (`OnboardingLive.refusalIsCurrent`); a start's own wait doesn't.
    public static func otherMacRefused(acrossRestarts: Bool = false) -> Bool {
        let own = ClusterService.published()?.child, now = Date().timeIntervalSince1970
        guard OnboardingLive.refusalIsCurrent(own: own, now: now, acrossRestarts: acrossRestarts) else { return false }
        return otherMacRefused(member: otherMacStatus()?.child, own: own, now: now, acrossRestarts: acrossRestarts)
    }

    /// Whether the other Mac's part reports the refusal, by the rule of the setup screen's ✗: that part runs and says so
    /// (`OnboardingLive.otherMacRefused`), and this Mac's part has run long enough for one more dial to reach it, or
    /// for a status read (`acrossRestarts`) its last part did (`OnboardingLive.refusalIsCurrent`).
    static func otherMacRefused(member: ClusterServiceStatus.Child?, own: ClusterServiceStatus.Child?, now: Double,
                                acrossRestarts: Bool = false) -> Bool {
        OnboardingLive.otherMacRefused(member) && OnboardingLive.refusalIsCurrent(own: own, now: now, acrossRestarts: acrossRestarts)
    }

    /// The other Mac's cluster service status: one `status` command over the cable, as the ✗'s readiness asks it, within
    /// `OnboardingLive.answerSeconds`; nil when it doesn't answer.
    static func otherMacStatus() -> ClusterServiceStatus? {
        guard let pairing = try? ClusterSetupLinkExchange.pairing(), let selection = try? LiveContext.defaultLinkSelection(),
              let body = try? JSONEncoder().encode(ClusterServiceCommand(op: .status)),
              let answer = try? ClusterSetupLinkExchange.command(pairing: pairing, selection: selection, peerAddress: nil,
                                                                 body: body, seconds: OnboardingLive.answerSeconds) else { return nil }
        return try? JSONDecoder().decode(ClusterServiceStatus.self, from: answer.reply)
    }

    /// `cluster status`'s reason and next step for `refused`, in the setup screens' words: on the refused Mac the joining
    /// Mac's lines (`ClusterOnboardingDriver.localNetworkBlockedLines`), on the other Mac the ✗'s
    /// (`OnboardingLive.localNetworkRefusalLines`). Each ends with the command that starts the pair again, instead of the
    /// screen's own step. `otherMac`: the other Mac as a sentence starts; `cli`: this build's command.
    public static func statusWords(_ refused: Refused, otherMac: String, app: String, cli: String) -> (reason: String, next: String) {
        switch refused {
        case .thisMac:
            let lines = ClusterOnboardingDriver.localNetworkBlockedLines(
                app: app, then: "then run `\(cli) start` here, or choose Retry in `\(cli) cluster` on the other Mac")
            return (lines[0].hasSuffix(".") ? String(lines[0].dropLast()) : lines[0], lines[1])
        case .otherMac:
            let lines = OnboardingLive.localNetworkRefusalLines(
                otherMac: otherMac, app: app, then: "Then run `\(cli) start` here, or choose Retry in `\(cli) cluster`")
            return (lines[0], lines[1])
        }
    }
}
