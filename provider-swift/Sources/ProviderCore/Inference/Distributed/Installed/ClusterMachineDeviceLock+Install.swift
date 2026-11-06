import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import Foundation

extension ClusterMachineDeviceLock {
    /// In a folder of its own that no app or build owns (the desktop app's is `…/Darkbloom`), created owner-only, which
    /// macOS never empties: every build takes `~/Library/Application Support/io.darkbloom.cluster/native-device.lock`.
    static let relativePath = "Library/Application Support/io.darkbloom.cluster/native-device.lock"

    /// Every refusal says this, so a part that ended on one is told apart from a part that fails (`isRefusal`).
    static let refusalMarker = "holds this Mac's GPU"

    /// The Mac's lock as `paths`' build takes it. Its refusal names the other app installed in the same home; a build
    /// other than production's also refuses while production serves here (`productionServingHere`), lock or not.
    static func forInstall(_ paths: ClusterUserPaths) -> ClusterMachineDeviceLock {
        let others = BuildEnvironment.allCases.filter { $0 != paths.environment && installed($0, home: paths.homeDirectory) }
        let home = paths.homeDirectory
        let olderProduction: (@Sendable () -> String?)? = paths.environment == .prod ? nil : { @Sendable in
            productionServingHere(home: home)
        }
        return .init(file: home.appendingPathComponent(relativePath), heldElsewhere: heldElsewhere(by: others),
                     otherHolder: olderProduction)
    }

    /// An install counts when its app or its `bin/` command is in its own folder (as `ProviderUninstallPaths.otherEnvironment`).
    static func installed(_ environment: BuildEnvironment, home: URL) -> Bool {
        let folder = environment.installDirectory(home: home)
        return [environment.appBundleName, "bin/\(environment.cliName)"].contains {
            var info = stat()
            return lstat(folder.appendingPathComponent($0).path, &info) == 0
        }
    }

    /// What a start says while another build's pair (or its model check) holds the lock. A build is never told to stop
    /// production: production serves here, and its owner decides.
    static func heldElsewhere(by others: [BuildEnvironment]) -> String {
        let fit = "for its pair (or a model check), and two pairs don't fit one Mac's memory"
        guard others.count == 1, let other = others.first else {
            return "Another Darkbloom app on this Mac \(refusalMarker) \(fit): this pair starts by itself once that app's stops."
        }
        if other == .prod {
            return "The production Darkbloom on this Mac \(refusalMarker) \(fit): this pair starts by itself once production's "
                + "stops. Production serves here: ask its owner before stopping it."
        }
        return "\(other.appDisplayName) on this Mac \(refusalMarker) \(fit): this pair starts by itself once \(other.appDisplayName)'s "
            + "stops, or now after `\(other.cliName) cluster stop`."
    }

    /// The refusal while production serves here (`productionServingHere`), `what` saying how: before 0.10.11 production
    /// takes no lock, and its single-Mac serving takes none in any version.
    static func productionServes(_ what: String) -> String {
        "The production Darkbloom on this Mac \(refusalMarker): \(what), and two pairs don't fit one Mac's memory: this pair "
            + "starts by itself once production stops serving here. Production serves here: ask its owner before stopping it."
    }

    /// Production serving on this Mac, in words, for another build (read only, never production's locks): a serving
    /// process of production's own app (`productionServing`), or production's cluster service saying its pair serves
    /// here (`productionPairStatus`), which also covers the seconds its part restarts (a crash, an update) and its wait
    /// for the GPU. A status that can't be read counts as serving (fail safe). Production wins by default.
    static func productionServingHere(home: URL) -> String? { productionServingCause(home: home).map(productionServes) }

    /// How production serves here, in words (`productionServingHere`), for a refusal to say; nil when it doesn't.
    static func productionServingCause(home: URL) -> String? {
        if let pid = productionServing(home: home) { return "it is serving (process \(pid))" }
        switch productionPairStatus(home: home) {
        case .none: return nil
        case .serves(let pid):
            return "its pair is set to serve here (its cluster service" + (pid.map { ", process \($0)" } ?? "") + ")"
        case .unreadable(let why):
            return "its cluster service's status can't be read (\(why)), so this build takes it that production serves here"
        }
    }

    /// How recently production's cluster service must have published its status to count: it writes it every second
    /// while it runs, so the seconds an update's restart takes stay covered, and a service that stopped for good stops
    /// counting two minutes later.
    static let publishedWithinSeconds: Double = 120

    /// What production's cluster service's published status says about this Mac, for another build.
    enum ProductionPairStatus: Equatable {
        /// No status (production isn't installed here, or its cluster service never ran), an old one (written two
        /// minutes ago or more, or dated ahead of this Mac's clock), or one saying production's pair doesn't serve here.
        case none
        /// Production's pair serves here, as the cluster service `servicePID` published within two minutes.
        case serves(servicePID: Int32?)
        /// A fresh status this build can't read or decode, and why: production may serve here, so the other build
        /// waits (fail safe) and says so.
        case unreadable(String)
    }

    /// Production's cluster service's published status (`ClusterServiceStatus.fileName` in production's setup folder),
    /// read only: never locked or written, and opened only as a regular file. Fresh: written within
    /// `publishedWithinSeconds` before it was looked at. It says the pair serves while its intent is on and the pair
    /// isn't given up on this Mac (`pairRunning`; nil from a build before 0.10.9).
    static func productionPairStatus(home: URL) -> ProductionPairStatus {
        guard let production = try? ClusterUserPaths(homeDirectory: home, environment: .prod) else { return .none }
        let file = production.setupDirectory.appendingPathComponent(ClusterServiceStatus.fileName)
        let shown = "~/\(BuildEnvironment.prod.installDirectoryName)/cluster-setup/\(ClusterServiceStatus.fileName)"
        func unreadable(errno code: Int32) -> ProductionPairStatus {
            .unreadable("\(shown): \(String(cString: strerror(code)))")
        }
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .none : unreadable(errno: code)
        }
        let written = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        // The clock is read after the stat, never before: production rewrites the file every second, and a time read
        // first could precede a write in between, which would then look dated ahead of the clock and not count.
        guard (0..<publishedWithinSeconds).contains(Date().timeIntervalSince1970 - written) else { return .none }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unreadable("\(shown) is not a file") }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return unreadable(errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 1 << 20),
              let status = try? JSONDecoder().decode(ClusterServiceStatus.self, from: data) else {
            return .unreadable("\(shown) is not a status this build can read")
        }
        return status.serving && status.pairRunning != false ? .serves(servicePID: status.servicePID) : .none
    }

    /// Whether a part's last error is one of these refusals (`ClusterApprovalCheck.memberQuickEnds`).
    static func isRefusal(_ text: String?) -> Bool { text?.contains(refusalMarker) == true }

    /// A process of production's own app that serves or runs a pair's part (`servesForProduction`), found in the process
    /// table, never by a lock or a file of production's: production builds before 0.10.11 take no GPU lock. Read only:
    /// each process's executable path first, and the arguments only of one inside production's folder. Nil when none runs.
    static func productionServing(home: URL, identifiers: [Int32] = ClusterMachineDeviceLock.runningIdentifiers(),
                                  executablePath: (Int32) -> String? = ClusterProcessTable.executablePath(of:),
                                  arguments: (Int32) -> [String]? = ClusterProcessTable.arguments(of:)) -> Int32? {
        let folder = resolved(BuildEnvironment.prod.installDirectory(home: home).path) + "/"
        return identifiers.first { identifier in
            guard identifier != getpid(), let path = executablePath(identifier),
                  let name = path.split(separator: "/").last.map(String.init),
                  name == BuildEnvironment.prod.cliName || name == ClusterOrphanReaper.workerExecutableName,
                  path.hasPrefix(folder) || resolved(path).hasPrefix(folder),
                  let arguments = arguments(identifier) else { return false }
            return servesForProduction(executableName: name, arguments: arguments)
        }
    }

    /// `darkbloom start …` (single-Mac serving, or a pair's part), `darkbloom cluster link-follower` (a pair's part that
    /// waits for its leader), `darkbloom cluster worker-owner` or the native worker (`ClusterOrphanReaper.role`).
    static func servesForProduction(executableName: String, arguments: [String]) -> Bool {
        if ClusterOrphanReaper.role(of: .init(processIdentifier: 0, arguments: arguments, executableName: executableName)) != nil {
            return true
        }
        guard executableName == BuildEnvironment.prod.cliName else { return false }
        let command = Array(arguments.dropFirst().prefix(2))
        return command.first == "start" || command == ["cluster", "link-follower"]
    }

    /// Every process on this Mac, by number (`proc_listallpids`).
    static func runningIdentifiers() -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var identifiers = [Int32](repeating: 0, count: capacity + 64)
        let filled = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return filled > 0 ? identifiers.prefix(Int(filled)).filter { $0 > 0 } : []
    }

    /// Another build's hold on this Mac's GPU now, read without keeping anything (`heldByAnotherBuild(_:otherHolder:)`
    /// with this build's own check for production).
    static func heldByAnotherBuild(_ paths: ClusterUserPaths) -> String? {
        heldByAnotherBuild(paths, otherHolder: forInstall(paths).otherHolder)
    }

    /// Production serving without the lock (`otherHolder`), or the lock held while this build's own lease is free (both
    /// probed shared for a moment, which a start waits out). Nil when nothing of another build holds it; this build's
    /// own scope is not another build's.
    static func heldByAnotherBuild(_ paths: ClusterUserPaths, otherHolder: (@Sendable () -> String?)?) -> String? {
        if let reason = otherHolder?() { return reason }
        let lock = forInstall(paths)
        guard isHeld(lock.file), !isHeld(paths.deviceLeaseFile) else { return nil }
        return lock.heldElsewhere
    }

    /// Whether another open file holds `file`'s flock now. An absent file is held by nobody.
    static func isHeld(_ file: URL) -> Bool {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }
}

/// How this Mac's part waits while another Darkbloom app holds the GPU (`ClusterMachineDeviceLock.heldByAnotherBuild`),
/// or after it stepped aside for production (`ClusterService`): it is not started and its refusals are not failures; it
/// starts on the first check after the hold ends.
enum ClusterOtherAppHold: Equatable {
    case none
    /// Waits; `say` the first time this hold is seen.
    case waits(String, say: Bool)
    /// The hold just ended: start now.
    case resumes

    static func step(before: String?, now: String?) -> Self {
        switch (before, now) {
        case (nil, nil): return .none
        case (_, let now?): return .waits(now, say: before != now)
        case (_?, nil): return .resumes
        }
    }
}

extension ClusterUserPaths {
    /// The device lock every Darkbloom build on this Mac shares (`ClusterMachineDeviceLock`): each native session,
    /// member preparation and GLM calibration holds it with this build's own device scope, so one build's pair never
    /// starts on the GPU beside another's.
    public var machineDeviceLock: ClusterMachineDeviceLock { .forInstall(self) }
}

/// Another Darkbloom build's hold on this Mac's GPU, for single-Mac serving and the `darkbloom` command.
public enum ClusterGPUHold {
    /// Why no model of this build loads on this Mac now (single-Mac serving): production serves here, in words
    /// (`ClusterMachineDeviceLock.productionServingCause`). Production's own build reads nothing and gets nil.
    public static func productionServesHere(environment: BuildEnvironment = .current,
                                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard environment != .prod, let cause = ClusterMachineDeviceLock.productionServingCause(home: home) else { return nil }
        return "The production Darkbloom on this Mac \(ClusterMachineDeviceLock.refusalMarker): \(cause), and two models don't "
            + "fit one Mac's memory: no model of this build loads here until production stops serving. Production serves "
            + "here: ask its owner before stopping it."
    }

    /// Whether `error` refused a start because another build holds this Mac's GPU, or production serves here.
    public static func refused(_ error: any Error) -> Bool { ClusterMachineDeviceLock.isRefusal("\(error)") }

    /// Why this build's pair can't take this Mac's GPU now (`ClusterMachineDeviceLock.heldByAnotherBuild`); nil when
    /// nothing of another build holds it.
    public static func now() -> String? {
        (try? ClusterUserPaths()).flatMap { ClusterMachineDeviceLock.heldByAnotherBuild($0) }
    }
}
