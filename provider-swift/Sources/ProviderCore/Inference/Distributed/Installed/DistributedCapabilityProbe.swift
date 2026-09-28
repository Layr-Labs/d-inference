import Foundation
import Darwin
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
        let bytes = try run(executable: executable.url, arguments: arguments, deadline: deadline)
        guard try ClusterRuntimeCapabilityCodec.decode(bytes) == plan.capability,
              ClusterConfigurationCodec.sha256(bytes) == plan.configuration.capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("Installed runtime description differs from the saved capability")
        }
        try executable.requireUnchanged()
        try DistributedInstalledFiles.check(deadline)
    }

    // Internal actual-child fixture seam. Production supplies only the fixed
    // describe-runtime command above after verifying its executable pin.
    static func run(executable: URL, arguments: [String], deadline: UInt64) throws -> Data {
        try DistributedInstalledFiles.check(deadline)
        let child = Process(), output = Pipe(), error = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = error
        let handles = [output.fileHandleForReading, error.fileHandleForReading]
        for handle in handles {
            let descriptor = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClusterConfigurationError.invalid("Cannot bound installed capability pipes")
            }
        }
        var launched = false
        defer {
            if launched {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        }
        try child.run(); launched = true
        try output.fileHandleForWriting.close(); try error.fileHandleForWriting.close()
        var data = [Data(), Data()], open = [true, true]
        let limits = [ClusterRuntimeCapabilityCodec.maximumBytes, 4096]
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
        child.waitUntilExit()
        try DistributedInstalledFiles.check(deadline)
        guard child.terminationReason == .exit, child.terminationStatus == 0, data[1].isEmpty else {
            throw ClusterConfigurationError.invalid("Installed capability command failed")
        }
        return data[0]
    }
}
