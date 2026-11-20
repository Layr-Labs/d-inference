import Darwin
import Foundation

/// Network serving runs only in a process the provider's launchd service
/// started: the provider job itself (launchd's own child, under the job's
/// label), or a part that a darkbloom launchd started runs (a cluster member
/// under the always-on supervisor or the cluster service). Anything else, for
/// example a copy another program started, does not serve the network.
///
/// The facts come from the kernel only (`proc_pidinfo`, `csops`, `uname`);
/// nothing here asks a Mach service, which the program that started a process
/// could answer for it.
public enum ServiceLaunchCheck {
    /// Release builds enforce it; debug builds (tests, development) serve from
    /// a terminal as before.
    public static var enforcedInThisBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Whether network serving also needs the kernel to report a process's
    /// original parent, which it does from macOS 15.4. Off in this build: on
    /// an earlier macOS, launchd's child is taken to be one launchd started.
    public static let requiresOriginalParentInThisBuild = false

    /// A process as the kernel reports it.
    public struct LaunchedProcess: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        /// The kernel's version of this pid (`p_idversion`).
        public var version: Int32
        /// The version of the process that started this one, kept when launchd
        /// adopts it (`p_orig_ppidversion`); nil on a kernel that does not
        /// report it (before macOS 15.4). Where the kernel reports it, 0 is kept
        /// and matches no process, so it refuses.
        public var originalParentVersion: Int32?
        /// The code signature the kernel validated; nil when it is not valid.
        public var signer: Signer?

        public init(pid: Int32, parent: Int32, version: Int32, originalParentVersion: Int32?, signer: Signer?) {
            self.pid = pid
            self.parent = parent
            self.version = version
            self.originalParentVersion = originalParentVersion
            self.signer = signer
        }
    }

    public struct Signer: Equatable, Sendable {
        public var teamID: String?
        public var identifier: String

        public init(teamID: String?, identifier: String) {
            self.teamID = teamID
            self.identifier = identifier
        }
    }

    public enum Refusal: Equatable, Sendable {
        /// Another program started it (or a process between it and launchd).
        case startedByAnotherProgram
        /// launchd adopted it after the program that started it exited.
        case adopted
        /// launchd started it, but not as the provider's job.
        case notTheProviderJob
        /// The kernel facts could not be read.
        case unknown
        /// This macOS (before 15.4) does not report a process's original
        /// parent, and the build requires it (`requireOriginalParent`).
        case originalParentUnreported
    }

    public enum Verdict: Equatable, Sendable {
        case serve
        case refuse(Refusal)
    }

    /// `chain` is this process, then its parent, grandparent and so on while
    /// they run this signed program, ending with launchd's child or with the
    /// first process that is not this program. `serviceName` is this process's
    /// `XPC_SERVICE_NAME`, which launchd sets to the job's label. With
    /// `requireOriginalParent`, a kernel that does not report original parents
    /// refuses: there, a process launchd adopted looks like one it started.
    public static func verdict(chain: [LaunchedProcess], launchdVersion: Int32, serviceName: String?,
                               isProviderJob: (String) -> Bool, requireOriginalParent: Bool = false) -> Verdict {
        guard let me = chain.first, me.signer != nil else { return .refuse(.unknown) }
        // One kernel reports every process in the chain, so this process's fact stands for all of them.
        if requireOriginalParent, me.originalParentVersion == nil { return .refuse(.originalParentUnreported) }
        if me.parent == 1 {
            guard startedByLaunchd(me, launchdVersion: launchdVersion) else { return .refuse(.adopted) }
            guard let serviceName, isProviderJob(serviceName) else { return .refuse(.notTheProviderJob) }
            return .serve
        }
        // A part: every process above it runs this program, up to one that launchd started. Only launchd adopts
        // processes, so a parent other than launchd started its child; the versions also rule out a reused pid.
        var child = me
        for ancestor in chain.dropFirst() {
            guard ancestor.pid == child.parent, ancestor.signer == me.signer,
                  child.originalParentVersion.map({ $0 == ancestor.version }) ?? true
            else { return .refuse(.startedByAnotherProgram) }
            if ancestor.parent == 1 {
                return startedByLaunchd(ancestor, launchdVersion: launchdVersion) ? .serve : .refuse(.adopted)
            }
            child = ancestor
        }
        return .refuse(.startedByAnotherProgram)
    }

    static func startedByLaunchd(_ process: LaunchedProcess, launchdVersion: Int32) -> Bool {
        process.parent == 1 && (process.originalParentVersion.map { $0 == launchdVersion } ?? true)
    }

    /// The provider's job labels: its LaunchAgent (solo provider or always-on
    /// cluster-member supervisor) and the cluster service's login agents, in
    /// this build's exact shape or production's (which builds wrote before they
    /// had prefixes of their own, `ClusterServiceAgentPlan.isAgentFileName`).
    public static func isProviderJob(_ label: String) -> Bool {
        label == LaunchAgent.label || isClusterServiceLabel(label)
    }

    static func isClusterServiceLabel(_ label: String) -> Bool {
        ClusterServiceAgentPlan.isAgentFileName(label + ".plist")
            || ClusterServiceAgentPlan.isAgentFileName(label + ".plist", environment: .prod)
    }

    /// A cluster service that launchd started under a label that is not one
    /// of Darkbloom's does not run: its parts would otherwise inherit its
    /// standing (`verdict` checks the label only for launchd's direct child).
    public static func refusesClusterService(_ verdict: Verdict) -> Bool {
        verdict == .refuse(.notTheProviderJob)
    }

    /// This process's verdict from the live kernel facts.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Verdict {
        guard let launchd = uniqueIdentifiers(1) else { return .refuse(.unknown) }
        return verdict(chain: liveChain(), launchdVersion: launchd.version,
                       serviceName: environment["XPC_SERVICE_NAME"], isProviderJob: isProviderJob,
                       requireOriginalParent: requiresOriginalParentInThisBuild)
    }

    static func liveChain(maxDepth: Int = 8) -> [LaunchedProcess] {
        var chain: [LaunchedProcess] = []
        var pid = getpid()
        while chain.count < maxDepth, let process = process(pid) {
            chain.append(process)
            guard process.parent > 1, process.signer != nil, process.signer == chain.first?.signer else { break }
            pid = process.parent
        }
        return chain
    }

    /// A process of this user (the kernel reports another user's parent only to root).
    static func process(_ pid: Int32) -> LaunchedProcess? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              let unique = uniqueIdentifiers(pid) else { return nil }
        return LaunchedProcess(pid: pid, parent: Int32(bitPattern: bsd.pbi_ppid), version: unique.version,
                       originalParentVersion: unique.originalParentVersion, signer: signer(pid))
    }

    /// `struct proc_uniqidentifierinfo` (56 bytes): uuid[16], uniqueid, puniqueid, idversion at 32 and, since
    /// macOS 15.4, orig_ppidversion at 36 (reserved and zero before). Readable for any process, launchd's included.
    static func uniqueIdentifiers(_ pid: Int32) -> (version: Int32, originalParentVersion: Int32?)? {
        var unique = [UInt8](repeating: 0, count: 56)
        guard proc_pidinfo(pid, 17 /* PROC_PIDUNIQIDENTIFIERINFO */, 0, &unique, 56) == 56 else { return nil }
        let version = unique.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: Int32.self) }
        let original = unique.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: Int32.self) }
        return (version, kernelReportsOriginalParent ? original : nil)
    }

    /// Darwin 24.4 (macOS 15.4) and later keep a process's original parent. Read from the kernel (`uname`), not
    /// from anything a process's environment can change; unreadable counts as reporting it (a 0 then refuses).
    static let kernelReportsOriginalParent: Bool = {
        var name = utsname()
        guard uname(&name) == 0 else { return true }
        let release = withUnsafeBytes(of: &name.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return reportsOriginalParent(darwinRelease: release)
    }()

    static func reportsOriginalParent(darwinRelease: String) -> Bool {
        let parts = darwinRelease.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return true }
        return (major, minor) >= (24, 4)
    }

    private typealias CodeSigningOperation = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

    /// The kernel's record of a process's code signature (`csops`): valid, its identifier and team.
    static func signer(_ pid: Int32) -> Signer? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "csops") else { return nil }
        let csops = unsafeBitCast(symbol, to: CodeSigningOperation.self)
        var status: UInt32 = 0
        guard csops(pid, 0 /* CS_OPS_STATUS */, &status, MemoryLayout<UInt32>.size) == 0,
              status & 0x1 /* CS_VALID */ != 0,
              let identifier = signingString(csops, pid, 11 /* CS_OPS_IDENTITY */)
        else { return nil }
        return Signer(teamID: signingString(csops, pid, 14 /* CS_OPS_TEAMID */), identifier: identifier)
    }

    /// An 8-byte blob header, then the NUL-terminated string.
    private static func signingString(_ csops: CodeSigningOperation, _ pid: Int32, _ operation: UInt32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1032)
        guard csops(pid, operation, &buffer, buffer.count) == 0,
              let end = buffer[8...].firstIndex(of: 0), end > 8 else { return nil }
        return String(decoding: buffer[8..<end], as: UTF8.self)
    }

    /// After a refusal: asks launchd to start the provider's job if the
    /// installed one is the refused kind (a cluster member's supervisor or a
    /// solo provider); nothing happens when it already runs, and a stopped
    /// (unloaded) job stays stopped. Returns whether launchd took the request.
    public static func startProviderJob(clusterMember: Bool) -> Bool {
        let plist = LaunchAgent.plistPath()
        guard FileManager.default.fileExists(atPath: plist.path),
              LaunchAgent.installedJobIsClusterMember(at: plist) == clusterMember else { return false }
        return LaunchctlControl.run(["kickstart", LaunchctlControl.target(label: LaunchAgent.label)],
                                    captureStderr: true).succeeded
    }
}
