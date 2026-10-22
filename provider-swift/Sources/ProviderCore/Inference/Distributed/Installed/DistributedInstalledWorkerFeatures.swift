import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import Darwin

/// What the pinned worker binary itself carries, read from its verified bytes.
///
/// The collective progress guard is what ends a rank whose peer has died: it
/// reads `JACCL_PROGRESS_TIMEOUT_MS`, so a runtime that has the guard contains
/// that name and one without it does not. An installed worker without the
/// guard would wait in a collective until its lifetime, so the installed path
/// refuses it. The startup-deadline argument is optional: an older worker that
/// does not know it is started without it and keeps only its lifetime.
struct DistributedInstalledWorkerFeatures: Sendable, Equatable {
    static let progressGuardMarker = "JACCL_PROGRESS_TIMEOUT_MS"
    static let startupDeadlineArgument = "--startup-deadline-uptime-nanoseconds"

    let hasProgressGuard: Bool
    let acceptsStartupDeadline: Bool
    /// S16: the worker keys its data plane (`--data-plane encrypted_v1` and a
    /// credential line); detected from the domain its pinned exchange signs.
    var acceptsDataPlane = false
    /// The worker takes its prefix-SSD key as a line of its input
    /// (`--prefix-ssd-key`); detected from the scheme name it compares.
    var acceptsPrefixSSDKeyInput = false
    var acceptsMiMoImageCandidate = false
    var acceptsGLMImageCandidate = false

    /// `executable` was just hashed against its pin; the caller re-checks that
    /// it did not change after this read.
    static func inspect(_ executable: DistributedInstalledFiles.Identity, deadline: UInt64) throws -> Self {
        try DistributedInstalledFiles.check(deadline)
        try executable.requireUnchanged()
        let descriptor = Darwin.open(executable.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot open the installed worker") }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_dev == executable.information.st_dev,
              information.st_ino == executable.information.st_ino, information.st_size == executable.information.st_size,
              information.st_size > 0, information.st_size <= 256 * 1024 * 1024 else {
            throw ClusterConfigurationError.invalid("Installed worker changed while it was inspected")
        }
        let count = Int(information.st_size)
        guard let mapped = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0), mapped != MAP_FAILED else {
            throw ClusterConfigurationError.invalid("Cannot read the installed worker")
        }
        defer { munmap(mapped, count) }
        func contains(_ text: String) -> Bool {
            let needle = Array(text.utf8)
            return needle.withUnsafeBytes { memmem(mapped, count, $0.baseAddress, $0.count) != nil }
        }
        let result = Self(hasProgressGuard: contains(progressGuardMarker), acceptsStartupDeadline: contains(startupDeadlineArgument),
            acceptsDataPlane: contains(ClusterDataPlaneLaunch.workerMarker),
            acceptsPrefixSSDKeyInput: contains(ClusterWorkerPrefixSSDKey.argument),
            acceptsMiMoImageCandidate:contains(ClusterMiMoImageCandidate.runtimeProfileArgument) && contains(ClusterMiMoImageCandidate.schema),
            acceptsGLMImageCandidate: contains(ClusterGLMImageCandidate.schema) && contains(ClusterGLMImageCandidate.profileID))
        try executable.requireUnchanged()
        try DistributedInstalledFiles.check(deadline)
        return result
    }

    /// With the prefix-SSD tier on, the worker must take its key on its input.
    /// An older worker read it from its environment, where every process of
    /// the same user can read it: it is refused, never given the key there.
    func requirePrefixSSDKeyInput(tierOn: Bool) throws {
        guard tierOn, !acceptsPrefixSSDKeyInput else { return }
        throw ClusterConfigurationError.invalid("Install the same Darkbloom release on both Macs. (The installed worker cannot take the prefix-SSD key on its input; an older worker would need it in its environment, which this owner never does.)")
    }

    func requireMiMoImageCandidate(required: Bool) throws {
        guard !required || (acceptsMiMoImageCandidate && hasProgressGuard && acceptsStartupDeadline && acceptsDataPlane) else {
            throw ClusterConfigurationError.invalid("Installed worker does not carry the exact private MiMo image profile and required guards")
        }
    }

    func requireGLMImageCandidate(required: Bool) throws {
        guard !required || (acceptsGLMImageCandidate && hasProgressGuard && acceptsStartupDeadline && acceptsDataPlane) else {
            throw ClusterConfigurationError.invalid("Installed worker lacks the GLM image profile or required guards")
        }
    }

    func requireProgressGuard() throws {
        guard hasProgressGuard else {
            throw ClusterConfigurationError.invalid("Installed worker has no collective progress guard (\(Self.progressGuardMarker)); a rank whose peer died would wait until its lifetime. Install a worker built with the guarded runtime.")
        }
    }
}
