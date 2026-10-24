import Darwin
import Foundation
import XCTest
@testable import ProviderAppAttest

/// These are real child/socket/kill/reap tests, not Apple qualification. The
/// unsigned test peer deliberately cannot pass production code authentication.
final class WorkerProcessTests: XCTestCase {
    private let peerProgram = #"""
import base64, json, os, signal, socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
mode = sys.argv[2]
if mode == "reply":
    header = os.read(3, 4)
    size = struct.unpack('!I', header)[0]
    body = b''
    while len(body) < size:
        body += os.read(3, size-len(body))
    s.sendall(header + body)
elif mode == "parent":
    body = json.dumps(base64.b64encode(s.getsockopt(0, 6, 32)).decode()).encode()
    s.sendall(struct.pack('!I', len(body)) + body)
elif mode == "stopped":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.kill(os.getpid(), signal.SIGSTOP)
# In never_callback mode there is no reply, ever. A supervisor must end this
# process; a late completion is not available to rescue the test.
time.sleep(120)
"""#

    private func launch(_ mode: String, listener: WorkerListener, slot: WorkerProcessSlot,
                        frame: WorkerFrame? = nil) throws -> (WorkerProcess, WorkerDescriptor) {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("system Python test peer unavailable") }
        let child = try slot.launch(executable: python, arguments: ["-c", peerProgram, listener.path, mode],
                                    bootstrap: WorkerFraming.encode(frame ?? WorkerFrame(generation: UUID(), sequence: 0, body: .authenticated)),
                                    epoch: slot.currentEpoch())
        let socket = try listener.accept(deadline: WorkerDeadline(seconds: 10))
        try slot.attach(socket, epoch: slot.currentEpoch())
        return (child, socket)
    }

    func testNeverReturningChildIsReapedBeforeReplacementCanReply() throws {
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let (stalled, socket) = try launch("never_callback", listener: listener, slot: slot)
        XCTAssertThrowsError(try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: WorkerDeadline(seconds: 0.03))) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .deadlineExceeded)
        }
        // A second process cannot bypass an outstanding owner, even before kill.
        XCTAssertThrowsError(try slot.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["120"], bootstrap: Data(), epoch: slot.currentEpoch()))
        try slot.cancel()
        XCTAssertThrowsError(try stalled.requireAlive())
        var status: Int32 = 0
        XCTAssertEqual(waitpid(stalled.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "the supervisor must reap, not merely signal")
        let expected = WorkerFrame(generation: UUID(), sequence: 1, body: .authenticated)
        let (replacement, replacementSocket) = try launch("reply", listener: listener, slot: slot, frame: expected)
        try replacement.requireAlive()
        let actual = try WorkerFraming.read(WorkerFrame.self, from: replacementSocket, deadline: WorkerDeadline(seconds: 5))
        XCTAssertEqual(actual.generation, expected.generation)
        XCTAssertEqual(actual.sequence, expected.sequence)
    }

    func testStoppedChildEscalatesToKillAndStaleCancellationCannotKillSuccessor() throws {
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let oldEpoch = try slot.currentEpoch()
        let (stalled, socket) = try launch("stopped", listener: listener, slot: slot)
        let stopDeadline = WorkerDeadline(seconds: 5)
        var status: Int32 = 0
        while true {
            let result = waitpid(stalled.pid, &status, WUNTRACED | WNOHANG)
            if result == stalled.pid {
                XCTAssertEqual(status & 0xff, 0x7f, "the child must actually be stopped before cancellation")
                break
            }
            try stopDeadline.check()
            usleep(1_000)
        }
        XCTAssertThrowsError(try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: WorkerDeadline(seconds: 0.03)))
        let started = ContinuousClock.now
        try slot.cancel(expectedEpoch: oldEpoch)
        let elapsed = (ContinuousClock.now - started).components
        XCTAssertGreaterThanOrEqual(elapsed.seconds, 2, "SIGTERM is ignored, so the grace period must elapse")
        XCTAssertLessThan(elapsed.seconds, 5)
        XCTAssertThrowsError(try stalled.requireAlive())
        XCTAssertEqual(waitpid(stalled.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let (replacement, _) = try launch("never_callback", listener: listener, slot: slot)
        try slot.cancel(expectedEpoch: oldEpoch)
        XCTAssertNoThrow(try replacement.requireAlive())
    }

    func testPermanentStopRejectsRespawn() throws {
        let slot = WorkerProcessSlot()
        let epoch = try slot.currentEpoch()
        try slot.cancel(permanently: true)
        XCTAssertThrowsError(try slot.currentEpoch())
        XCTAssertThrowsError(try slot.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["120"], bootstrap: Data(), epoch: epoch))
    }

    func testQualificationSuspendsOnlyCurrentOwnedWorkerOnce() throws {
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let epoch = try slot.currentEpoch()
        let (child, _) = try launch("never_callback", listener: listener, slot: slot)
        try slot.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: child)
        XCTAssertEqual(try processStatus(child), UInt32(SSTOP))
        XCTAssertNoThrow(try child.requireAlive(), "a stopped child is still owned, not reaped")
        XCTAssertThrowsError(try slot.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: child)) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .busy)
        }
        try slot.cancel(permanently: true)
        XCTAssertThrowsError(try child.requireAlive())
        XCTAssertNoThrow(try slot.cancel(permanently: true), "repeated stop must remain safe")
    }

    func testCancelledQualificationCannotSuspendReplacementOrReapedProcess() throws {
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let oldEpoch = try slot.currentEpoch()
        let (old, _) = try launch("never_callback", listener: listener, slot: slot)
        try slot.cancel(expectedEpoch: oldEpoch)
        let (replacement, _) = try launch("never_callback", listener: listener, slot: slot)
        let newEpoch = try slot.currentEpoch()
        for (epoch, process) in [(oldEpoch, old), (oldEpoch, replacement), (newEpoch, old)] {
            XCTAssertThrowsError(try slot.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: process)) {
                XCTAssertEqual($0 as? AppAttestWorkerError, .staleExchange)
            }
        }
        XCTAssertThrowsError(try old.suspendOwnedWorkerForQualification()) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .connectionClosed)
        }
        XCTAssertNotEqual(try processStatus(replacement), UInt32(SSTOP))
        XCTAssertNoThrow(try replacement.requireAlive())
    }

    func testConcurrentQualificationAndCancellationSerializeSignalWithReaping() throws {
        for _ in 0..<8 {
            let slot = WorkerProcessSlot(), listener = try WorkerListener()
            defer { try? slot.cancel(permanently: true) }
            let epoch = try slot.currentEpoch()
            let (child, _) = try launch("never_callback", listener: listener, slot: slot)
            let start = DispatchSemaphore(value: 0), ready = DispatchGroup(), finished = DispatchGroup()
            for action in 0..<2 {
                ready.enter(); finished.enter()
                DispatchQueue.global().async {
                    ready.leave()
                    start.wait()
                    defer { finished.leave() }
                    do {
                        if action == 0 {
                            try slot.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: child)
                        } else {
                            try slot.cancel(expectedEpoch: epoch)
                        }
                    } catch {
                        // Cancellation won the ownership lock before the fault.
                        XCTAssertEqual(action, 0)
                        XCTAssertEqual(error as? AppAttestWorkerError, .staleExchange)
                    }
                }
            }
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
            start.signal(); start.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
            XCTAssertThrowsError(try child.requireAlive())
            var status: Int32 = 0
            XCTAssertEqual(waitpid(child.pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
            let (replacement, _) = try launch("never_callback", listener: listener, slot: slot)
            XCTAssertThrowsError(try slot.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: child))
            XCTAssertNotEqual(try processStatus(replacement), UInt32(SSTOP))
        }
    }

    private func processStatus(_ child: WorkerProcess) throws -> UInt32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw AppAttestWorkerError.connectionClosed
        }
        return info.pbi_status
    }

    func testHiddenEntryRejectsUnauthenticatedLaunchBeforeOrdinaryCLI() throws {
        let bundle = Bundle(for: Self.self).bundleURL
        let executable = bundle.deletingLastPathComponent().appendingPathComponent("darkbloom")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [AppAttestWorkerHost.argument]
        process.environment = ["HOME": home.path, "DARKBLOOM_NO_UPDATE_CHECK": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = WorkerDeadline(seconds: 5)
        while process.isRunning, deadline.remaining > 0 { usleep(1_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 78)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty,
                      "the hidden mode must not run normal CLI help, notices or diagnostics")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    func testKernelTokenIdentifiesActualChildAndParentNotClaims() throws {
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let (child, socket) = try launch("parent", listener: listener, slot: slot)
        let peer = try WorkerAuditIdentity.peer(socket)
        let own = try WorkerAuditIdentity.current()
        XCTAssertEqual(peer.pid, child.pid)
        XCTAssertEqual(peer.uid, geteuid())
        XCTAssertNotEqual(peer.bytes, own.bytes)
        let observedParent = try WorkerFraming.read(Data.self, from: socket, deadline: WorkerDeadline(seconds: 5))
        XCTAssertEqual(observedParent, own.bytes)
        XCTAssertNoThrow(try peer.code())
    }

    func testUnsignedSelfAndWrongCodePeerNeverPassProductionRequirement() throws {
        // XCTest (even if development-signed) is not the qualified provider.
        XCTAssertThrowsError(try WorkerCodeIdentity.current()) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .unauthenticatedPeer)
        }
        let slot = WorkerProcessSlot(), listener = try WorkerListener()
        defer { try? slot.cancel(permanently: true) }
        let (child, socket) = try launch("never_callback", listener: listener, slot: slot)
        let peer = try WorkerAuditIdentity.peer(socket)
        let expected = WorkerCodeIdentity(cdHash: Data(repeating: 1, count: 20), binaryHash: String(repeating: "a", count: 64), executable: URL(fileURLWithPath: "/not-used"))
        XCTAssertThrowsError(try expected.authenticate(peer, expectedPID: child.pid)) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .unauthenticatedPeer)
        }
        XCTAssertThrowsError(try expected.authenticate(peer, expectedPID: getpid()))
        XCTAssertThrowsError(try expected.authenticate(peer, expectedPID: child.pid, expectedAudit: WorkerAuditIdentity.current().bytes))
    }
}
