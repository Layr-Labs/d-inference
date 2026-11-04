import Foundation
import Darwin
import DarkbloomClusterProcess

/// Keeps a native cluster worker off a Mac whose ordinary provider is running.
///
/// The ordinary provider does not take the cluster's device scope, so nothing
/// else stops a worker from loading its model beside a provider that is already
/// using the same GPU and memory. Every long-running provider holds an
/// exclusive lock on its instance lock file and records its process there.
/// The owner refuses to start a worker while that lock is held, unless the
/// holder is itself part of this cluster:
///
/// - the process that launched this owner (the leader holds the lock for its
///   own session and starts its local owner as a direct child), or
/// - a control-only cluster member (`start --cluster-member`), which serves
///   nothing by itself.
///
/// This is a check at launch, not a held lock: a provider started afterwards
/// is not prevented by it.
enum DistributedInstalledProviderExclusion {
    struct Refusal: Error, Equatable, CustomStringConvertible {
        let processIdentifier: Int32?
        var description: String {
            let holder = processIdentifier.map { "process \($0)" } ?? "another process"
            return "An ordinary Darkbloom provider (\(holder)) is running on this Mac and holds the provider instance lock. "
                + "A cluster worker cannot share the GPU with it. Stop it with `darkbloom stop`, then start the cluster again."
        }
    }

    static func requireNoOrdinaryProvider(lockFile: URL, parent: Int32 = getppid(),
        arguments: (Int32) -> [String]? = ClusterProcessTable.arguments(of:)) throws {
        let descriptor = Darwin.open(lockFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return } // No provider ever ran here.
        guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot inspect the provider instance lock") }
        defer { Darwin.close(descriptor) }
        // A shared probe succeeds only when no provider holds its exclusive
        // lock. It is released at once and never held across a launch.
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 { _ = flock(descriptor, LOCK_UN); return }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw ClusterConfigurationError.invalid("Cannot inspect the provider instance lock")
        }
        guard let holder = recordedHolder(descriptor) else { throw Refusal(processIdentifier: nil) }
        if holder == parent { return }
        if let line = arguments(holder), line.contains("--cluster-member") { return }
        throw Refusal(processIdentifier: holder)
    }

    /// The holder writes one small JSON record naming its process.
    private static func recordedHolder(_ descriptor: Int32) -> Int32? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0, let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
              let value = object["pid"] as? Int, value > 0, value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }
}
