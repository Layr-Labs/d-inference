import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw OwnerWire.invalid(message) }
}

@main struct OwnerDiagnosticDrainTests {
    static let expected = Data("fake-native: selected failure\n".utf8)

    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { Darwin.exit(64) }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30)
        let owner = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        try await late(owner, worker, root, behavior: "normal")
        #if OWNER_DIAGNOSTIC_DRAIN
        try await late(owner, worker, root, behavior: "abnormal")
        try await late(owner, worker, root, behavior: "hang")
        try retainedWriter(worker)
        try excessiveBytes(worker)
        print("owner-diagnostic-drain: 5 actual-child/pipe groups passed")
        #else
        print("owner-diagnostic-drain: baseline lost post-ACK diagnostic reproduced")
        #endif
        alarm(0)
    }

    static func late(_ owner: URL, _ worker: URL, _ root: URL, behavior: String) async throws {
        let directory = root.appendingPathComponent(behavior)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let start = DispatchTime.now().uptimeNanoseconds
        let endpoint = try ClusterRemoteWorkerEndpoint(transport: .init(executable: owner,
            arguments: [worker.path, directory.path, behavior], environment: [:]), clusterID: "cpu-test",
            expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan,
            lifetimeDeadlineUptimeNanoseconds: start + 10_000_000_000)
        // Receiving a terminal must not make the pre-Ready failure a success.
        do {
            _ = try endpoint.receiveWorkerEvent(until: start + 5_000_000_000)
            throw OwnerWire.invalid("Failing child unexpectedly produced a worker event")
        } catch ClusterWorkerOwnerError.closed { }
        while !endpoint.ownerDeviceLeaseReleasedObserved && DispatchTime.now().uptimeNanoseconds < start + 5_000_000_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(endpoint.nativeCleanupObserved && endpoint.ownerDeviceLeaseReleasedObserved,
            "Actual native cleanup and authenticated ACK must precede fixture diagnostic")
        try require(endpoint.diagnosticTail.isEmpty, "Late diagnostic was emitted before test opened gate")
        try Data([1]).write(to: directory.appendingPathComponent("emit-after-ack"), options: .withoutOverwriting)
        let released = await endpoint.waitUntilOwnerReleased(deadline: start + 6_000_000_000)
        let emitted = try Data(contentsOf: directory.appendingPathComponent("emitted-diagnostic"))
        try require(emitted == expected, "Actual owner did not emit fixed child diagnostic")
        try require(endpoint.nativeCleanupObserved && endpoint.ownerDeviceLeaseReleasedObserved,
            "Transport drain changed native/lease proofs")
        #if OWNER_DIAGNOSTIC_DRAIN
        try require(endpoint.diagnosticTail == expected && endpoint.diagnosticDrainComplete,
            "Post-ACK bytes or EOF lost before owner-ended barrier")
        if behavior == "normal" {
            try require(released && endpoint.ownerTermination == .exited(0), "Natural owner return not observed")
        } else if behavior == "abnormal" {
            try require(!released && endpoint.ownerTermination == .exited(9), "Abnormal exit fabricated clean release")
        } else {
            try require(!released && endpoint.ownerTermination == .signalled(SIGKILL), "Hung owner escaped bounded transport fence")
            try require(DispatchTime.now().uptimeNanoseconds - start < 5_000_000_000, "Exit grace was extended")
        }
        #else
        try require(released && endpoint.ownerTermination == .exited(0) && endpoint.diagnosticTail.isEmpty,
            "Baseline no longer reproduces unread post-ACK bytes")
        #endif
        let journal = try Data(contentsOf: directory.appendingPathComponent("native-device.lease"))
        try require(journal.isEmpty, "Actual service journal was not released")
    }

    #if OWNER_DIAGNOSTIC_DRAIN
    static func child(_ worker: URL, arguments: [String], error: Pipe) throws -> Process {
        let value = Process()
        value.executableURL = worker; value.arguments = arguments; value.environment = [:]
        value.standardInput = FileHandle.nullDevice; value.standardOutput = FileHandle.nullDevice; value.standardError = error
        try value.run()
        try error.fileHandleForWriting.close()
        return value
    }

    static func reader(_ pipe: Pipe) throws -> ClusterOwnerDiagnostics {
        let fd = pipe.fileHandleForReading.fileDescriptor
        try require(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "Cannot make test pipe nonblocking")
        return ClusterOwnerDiagnostics(descriptor: fd)
    }

    static func retainedWriter(_ worker: URL) throws {
        let pipe = Pipe(), capture = try reader(pipe)
        let retained = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        try require(retained >= 0, "Cannot retain test-owned writer")
        var writerOpen = true
        defer { if writerOpen { Darwin.close(retained) }; try? pipe.fileHandleForReading.close() }
        let process = try child(worker, arguments: [], error: pipe)
        process.waitUntilExit()
        let start = DispatchTime.now().uptimeNanoseconds
        capture.drain(until: start + 80_000_000)
        try require(process.terminationReason == .exit && process.terminationStatus == 7,
            "Actual child termination not observed")
        try require(capture.snapshot == expected && !capture.isComplete,
            "Child exit fabricated EOF while a writer is retained")
        try require(DispatchTime.now().uptimeNanoseconds - start < 500_000_000, "Missing EOF exceeded drain deadline")
        Darwin.close(retained); writerOpen = false
        capture.drain(until: DispatchTime.now().uptimeNanoseconds + 100_000_000)
        try require(capture.isComplete, "Closing final writer failed to expose actual EOF")
    }

    static func excessiveBytes(_ worker: URL) throws {
        let pipe = Pipe(), capture = try reader(pipe)
        defer { try? pipe.fileHandleForReading.close() }
        let process = try child(worker, arguments: ["large"], error: pipe)
        capture.drain(until: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == 7,
            "Oversize diagnostic child did not actually exit")
        try require(!capture.isComplete && capture.snapshot.count <= ClusterOwnerDiagnostics.maximumBytes,
            "Diagnostic byte overflow was accepted or unbounded")
    }
    #endif
}
