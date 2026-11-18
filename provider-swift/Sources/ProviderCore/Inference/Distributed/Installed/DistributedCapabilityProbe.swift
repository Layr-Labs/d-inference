import Foundation
import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterProtocol

/// The installed worker already provides a bounded metadata-only command. Run
/// that exact command privately and compare its complete canonical response.
/// This direct child is not a generation owner and acquires no device lease.
enum DistributedCapabilityProbe {
    static func verify(plan: DistributedInstalledPlan, executable: DistributedInstalledFiles.Identity,
                       deadline: UInt64) throws {
        try executable.requireUnchanged()
        let arguments = ["--describe-runtime", "--config", plan.configurationURL.path,
            "--manifest", plan.manifestURL.path, "--expected-executable-sha256", plan.capability.runtimeBinarySHA256]
            + (!plan.capability.hasPrivateImages ? [] : [ClusterMiMoImageCandidate.runtimeProfileArgument,plan.capability.profile.id])
        // The worker it describes is the one verified above: its launch is bound to those bytes (and, in a signed
        // provider, to the worker's signature), as its native launch is.
        let bytes = try run(executable: executable.url, arguments: arguments, deadline: deadline,
                            maximumOutputBytes: ClusterRuntimeCapabilityCodec.maximumBytes,
                            verifyLaunched: try executable.launchVerifier(.worker))
        // A record this build cannot read is a mixed install, and is said so;
        // one it can read but that differs is a worker changed since setup.
        let described = try ClusterCapabilityRecord.decode(bytes, writtenBy: "the installed worker (\(executable.url.path))")
        guard described == plan.capability,
              ClusterConfigurationCodec.sha256(bytes) == plan.configuration.capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("Darkbloom changed on this Mac since the cluster was set up: run `darkbloom cluster` again; it sets up again by itself. (The installed worker's runtime description differs from the saved capability.)")
        }
        try executable.requireUnchanged()
        try DistributedInstalledFiles.check(deadline)
    }

    /// Runs a metadata-only command of one of this Mac's cluster helpers (the worker's `--describe-runtime`, the
    /// placement tool) and returns what it printed. A provider signed with a certificate checks the file against
    /// `helper`'s requirement before the spawn and the suspended child before it runs
    /// (`DistributedInstalledHelperSignature.metadataVerifier`), so nothing a helper signed otherwise prints is read.
    /// `helper` is nil only for a command that is none of this Mac's helpers (the developer route's SSH client).
    static func run(executable: URL, arguments: [String], deadline: UInt64,
                    maximumOutputBytes: Int = ClusterRuntimeCapabilityCodec.maximumBytes,
                    helper: DistributedInstalledHelper?,
                    signature: DistributedInstalledHelperSignature = .current) throws -> Data {
        try succeeded(outcome(executable: executable, arguments: arguments, deadline: deadline,
                              maximumOutputBytes: maximumOutputBytes, helper: helper, signature: signature))
    }

    static func run(executable: URL, arguments: [String], deadline: UInt64, maximumOutputBytes: Int,
                    verifyLaunched: (@Sendable (pid_t) throws -> Void)?) throws -> Data {
        try succeeded(outcome(executable: executable, arguments: arguments, deadline: deadline,
                              maximumOutputBytes: maximumOutputBytes, verifyLaunched: verifyLaunched))
    }

    /// What a command that exited printed, whatever its status: for a caller that reports a helper's own
    /// refusal (its first line on standard error). Checked exactly as `run`; a child that ended by a signal throws.
    struct Outcome: Sendable, Equatable {
        let status: Int32
        let output: Data
        let error: Data
        var errorText: String { String(decoding: error, as: UTF8.self) }
    }

    static func outcome(executable: URL, arguments: [String], deadline: UInt64, maximumOutputBytes: Int,
                        helper: DistributedInstalledHelper?,
                        signature: DistributedInstalledHelperSignature = .current) throws -> Outcome {
        try DistributedInstalledFiles.check(deadline)
        let verify = try helper.flatMap { try signature.metadataVerifier($0, file: executable, deadline: deadline) }
        return try outcome(executable: executable, arguments: arguments, deadline: deadline,
                           maximumOutputBytes: maximumOutputBytes, verifyLaunched: verify)
    }

    private static func succeeded(_ outcome: Outcome) throws -> Data {
        guard outcome.status == 0, outcome.error.isEmpty else {
            throw ClusterConfigurationError.invalid("Installed capability command failed")
        }
        return outcome.output
    }

    /// The bounded run itself. With `verifyLaunched` the child is spawned suspended and runs only once the check
    /// accepted it (`ClusterChildProcess`); a refused child is killed and reaped, and the run fails before reading.
    static func outcome(executable: URL, arguments: [String], deadline: UInt64, maximumOutputBytes: Int,
                        verifyLaunched: (@Sendable (pid_t) throws -> Void)?) throws -> Outcome {
        try DistributedInstalledFiles.check(deadline)
        let input = Pipe(), output = Pipe(), error = Pipe()
        let child = ClusterChildProcess(launch: .init(executable: executable, arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"], verifyLaunched: verifyLaunched),
            standardInput: input, standardOutput: output, standardError: error)
        let handles = [output.fileHandleForReading, error.fileHandleForReading]
        for handle in handles {
            let descriptor = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClusterConfigurationError.invalid("Cannot bound installed capability pipes")
            }
        }
        // The child's exit is taken from Foundation's termination handler.
        // waitUntilExit() can sleep on a dispatch thread after the child is
        // already gone, which would hold this bounded probe open.
        let exit = ClusterProcessExit()
        var launched = false
        defer {
            if launched {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                exit.wait()
            }
            for handle in handles { try? handle.close() }
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        }
        try exit.run(child); launched = true
        // The command reads nothing: its input ends at once.
        try input.fileHandleForWriting.close(); try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close(); try error.fileHandleForWriting.close()
        var data = [Data(), Data()], open = [true, true]
        let limits = [maximumOutputBytes, 4096]
        while open.contains(true) || child.isRunning {
            try DistributedInstalledFiles.check(deadline)
            var descriptors = handles.enumerated().map { index, handle in
                pollfd(fd: open[index] ? handle.fileDescriptor : -1, events: Int16(POLLIN), revents: 0)
            }
            let status = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 50) }
            if status < 0 && errno == EINTR { continue }
            guard status >= 0 else { throw ClusterConfigurationError.invalid("Capability output poll failed") }
            for index in 0..<2 where descriptors[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(handles[index].fileDescriptor, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count >= 0, count <= limits[index] - data[index].count else {
                    throw ClusterConfigurationError.invalid("Capability output exceeded its bound")
                }
                if count == 0 { open[index] = false }
                else { data[index].append(contentsOf: buffer.prefix(count)) }
            }
        }
        exit.wait()
        try DistributedInstalledFiles.check(deadline)
        guard child.terminationReason == .exit else { throw ClusterConfigurationError.invalid("Installed capability command failed") }
        return .init(status: child.terminationStatus, output: data[0], error: data[1])
    }
}
