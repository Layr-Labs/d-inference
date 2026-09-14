import Foundation
@testable import SandboxRuntimeVZ
import XCTest

final class SandboxGUISessionMonitorTests: XCTestCase {
    private enum Probe: Error { case checked }

    private final class Contexts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SandboxProcessSecurityContextSnapshot]
        init(_ values: [SandboxProcessSecurityContextSnapshot]) { self.values = values }
        func capture() -> SandboxProcessSecurityContextSnapshot {
            lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
        }
    }

    private func context(uid: UInt32 = 501, sessionID: UInt32 = 42, attributes: UInt32 = 0x10,
                         status: Int32 = 0, auditUID: UInt32 = 501) -> SandboxProcessSecurityContextSnapshot {
        .init(realUID: uid, effectiveUID: uid, sessionStatus: status, sessionID: sessionID,
              sessionAttributes: attributes, auditStatus: 0, auditUID: auditUID)
    }

    func testUnavailableInitialSessionFailsBeforeServiceStarts() {
        for snapshot in [context(attributes: 0), context(status: -1), context(auditUID: 0)] {
            XCTAssertThrowsError(try SandboxGUISessionMonitor(capture: { snapshot }, sleep: {})) { error in
                guard case SandboxGUISessionError.unavailable = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testSessionOrIdentityLossStopsMonitoringImmediately() async throws {
        for changed in [context(sessionID: 43), context(attributes: 0), context(attributes: 0x1010),
                        context(status: -1), context(auditUID: 0), context(uid: 502, auditUID: 502)] {
            let source = Contexts([context(), changed])
            let monitor = try SandboxGUISessionMonitor(capture: { source.capture() }, sleep: { throw Probe.checked })
            do {
                try await monitor.run()
                XCTFail("expected session loss")
            } catch SandboxGUISessionError.changed { } catch { XCTFail("unexpected error: \(error)") }
        }
    }

    func testSameSessionAllowsUnrelatedAttributeChanges() async throws {
        let source = Contexts([context(), context(attributes: 0x30)])
        let monitor = try SandboxGUISessionMonitor(capture: { source.capture() }, sleep: { throw Probe.checked })
        do {
            try await monitor.run()
            XCTFail("expected probe completion")
        } catch Probe.checked { } catch { XCTFail("unexpected error: \(error)") }
    }

    func testCancellationInterruptsMonitoringSleep() async throws {
        let snapshot = context()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let monitor = try SandboxGUISessionMonitor(capture: { snapshot }, sleep: {
            continuation.yield(()); continuation.finish()
            try await Task.sleep(for: .seconds(30))
        })
        let task = Task { try await monitor.run() }
        for await _ in started { break }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError { } catch { XCTFail("unexpected error: \(error)") }
    }
}
