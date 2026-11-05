import Foundation
import Darwin
import DarkbloomClusterProcess

/// Who holds this Mac's provider instance lock (`provider.pid.lock`): one serving process per Mac. A single-Mac provider
/// (`darkbloom start --solo`, the app's Go Online, its login job) and this Mac's part of a two-Mac pair (the cluster
/// service's part, a `--cluster-member`, a `--distributed` session) all take it, and each records only its process and
/// "provider-instance". Which one it is decides what the screens say and what to run: `darkbloom stop --solo` stops
/// single-Mac serving; plain `darkbloom stop` on a paired Mac stops the pair.
public enum ProviderInstanceHolder {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// An ordinary single-Mac provider: it never ends by itself, and a pair can't start beside it.
        case singleMac
        /// This Mac's part of the pair (or the cluster service's own degraded server).
        case pairPart
    }

    public struct Holder: Sendable, Equatable {
        /// The process its lock record names, nil when the record names none.
        public var pid: Int32?
        public var kind: Kind
        public init(pid: Int32?, kind: Kind) { self.pid = pid; self.kind = kind }
    }

    /// The operation every serving process records on the lock (`ProcessLifecycle.acquireSingleInstanceLock`).
    public static let operation = "provider-instance"

    public static func defaultLockFile() -> URL { ProcessLifecycle.defaultPIDFile().appendingPathExtension("lock") }

    /// Which kind a holder is, from its arguments and its parent's: a part of the pair runs `--distributed` or
    /// `--cluster-member`, or is a child of a cluster service (`<cli> cluster service …`; its degraded server runs
    /// `start --local`, as the app's local mode does). A holder whose arguments can't be read is not assumed a part.
    public static func kind(arguments: [String]?, parentArguments: [String]?) -> Kind {
        if let arguments, arguments.dropFirst().contains(where: { $0 == "--distributed" || $0 == "--cluster-member" }) { return .pairPart }
        if let parent = parentArguments, parent.count >= 3, parent[1] == "cluster", parent[2] == "service" { return .pairPart }
        return .singleMac
    }

    /// `pid`'s kind from the process table (no files read).
    public static func kind(of pid: Int32, arguments: (Int32) -> [String]? = ClusterProcessTable.arguments(of:),
                            parent: (Int32) -> Int32? = ClusterProcessTable.parentProcessIdentifier(of:)) -> Kind {
        kind(arguments: arguments(pid), parentArguments: parent(pid).flatMap(arguments))
    }

    /// The holder of `lockFile` now, nil when nothing holds it (or no provider ever ran here). A shared probe that is
    /// released at once: it never keeps a provider from starting.
    public static func current(lockFile: URL = defaultLockFile(),
                               arguments: (Int32) -> [String]? = ClusterProcessTable.arguments(of:),
                               parent: (Int32) -> Int32? = ClusterProcessTable.parentProcessIdentifier(of:)) -> Holder? {
        let descriptor = Darwin.open(lockFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { _ = flock(descriptor, LOCK_UN); return nil }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { return nil }
        let pid = recordedPID(descriptor)
        return Holder(pid: pid, kind: pid.map { kind(of: $0, arguments: arguments, parent: parent) } ?? .singleMac)
    }

    /// The single-Mac provider serving on this Mac now, nil when none does (nothing holds the lock, or this Mac's part
    /// of the pair does).
    public static func singleMacServing(lockFile: URL = defaultLockFile()) -> Holder? {
        singleMac(current(lockFile: lockFile), recordedPartPID: ClusterService.recordedPart(ClusterService.published())?.pid)
    }

    /// `holder` when it is single-Mac serving: never this Mac's pair part the cluster service recorded (`recordedPartPID`),
    /// even once it outlived its service and launchd adopted it (an orphaned part, whose arguments read like `start
    /// --local`): `stop --solo` can't stop it, so the person is never told to.
    public static func singleMac(_ holder: Holder?, recordedPartPID: Int32?) -> Holder? {
        guard let holder, holder.kind == .singleMac else { return nil }
        if let recordedPartPID, holder.pid == recordedPartPID { return nil }
        return holder
    }

    /// "a single-Mac Darkbloom provider (process 9523) is serving on this Mac" / "this Mac's part of the two-Mac pair
    /// (process 9523) is running": the lock's owner in words, never "an update".
    public static func clause(_ holder: Holder) -> String {
        let process = holder.pid.map { "process \($0)" } ?? "a process it doesn't name"
        switch holder.kind {
        case .singleMac: return "a single-Mac Darkbloom provider (\(process)) is serving on this Mac"
        case .pairPart: return "this Mac's part of the two-Mac pair (\(process)) is running"
        }
    }

    /// What to run for a single-Mac provider on `mac`: `<cli> stop --solo` stops single-Mac serving only, never the pair.
    public static func soloRemedy(cli: String = BuildEnvironment.current.cliName, on mac: String = "this Mac") -> String {
        "Stop it with `\(cli) stop --solo` on \(mac), then start the pair again (`\(cli) start`)."
    }

    static func recordedPID(_ descriptor: Int32) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0, let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
              let value = object["pid"] as? Int, value > 0, value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }
}
