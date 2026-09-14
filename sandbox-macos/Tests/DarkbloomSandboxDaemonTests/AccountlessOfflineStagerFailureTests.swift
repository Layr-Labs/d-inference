import Darwin
import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessOfflineStagerFailureTests: XCTestCase {
    func testAttachFailureRecordsIntentFirstAndClosesOnlyAfterIndependentAbsenceChecks() async throws {
        let f = try await AccountlessOfflineOverlayTestFixture(); defer { f.remove() }
        let journal = try f.journal()
        let image = f.installation.base.root.appendingPathComponent("mount-source")
        try Data("source".utf8).write(to: image)
        let descriptor = open(image.path, O_RDONLY | O_CLOEXEC); defer { close(descriptor) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var calls: [(AccountlessMountSystemTools.Tool, [String])] = []
        let tools = AccountlessMountSystemTools { tool, arguments, _ in
            calls.append((tool, arguments))
            if tool == .hdiutil, arguments == ["info", "-plist"] { return try self.emptyInventory() }
            if tool == .lsof { return self.result("p\(getpid())\nf\(descriptor)\n") }
            if tool == .hdiutil, arguments.first == "attach" {
                let attempts = try journal.mountAttempts().existing()
                XCTAssertNotNil(try attempts.last?.intent(), "intent must be durable before launch")
                XCTAssertNil(try attempts.last?.completion())
                return self.result("", code: 1)
            }
            XCTFail("unexpected command \(tool) \(arguments)"); throw AccountlessDiskError.commandFailed
        }
        let stager = AccountlessOfflineStager(journal: journal, tools: tools, image: image,
            imageDescriptor: descriptor, validateOwnership: {})
        do { try await stager.stage(payloadDirectory: f.installation.destination); XCTFail("attach should fail") }
        catch { XCTAssertEqual(error as? AccountlessDiskError, .commandFailed) }
        let attempt = try XCTUnwrap(journal.mountAttempts().existing().last)
        XCTAssertNotNil(try attempt.completion())
        XCTAssertFalse(try journal.isStaged())
        XCTAssertEqual(calls.filter { $0.0 == .lsof }.count, 2)
        XCTAssertFalse(calls.contains { $0.1.first == "mount" || $0.1.first == "detach" })
    }

    func testPendingClientDoesNotStartCleanupAndLaterRecoveryClosesTheOldAttemptBeforeNewAttach() async throws {
        let f = try await AccountlessOfflineOverlayTestFixture(); defer { f.remove() }
        let journal = try f.journal(), image = f.installation.base.root.appendingPathComponent("mount-source")
        try Data("source".utf8).write(to: image)
        let descriptor = open(image.path, O_RDONLY | O_CLOEXEC); defer { close(descriptor) }
        var pending = true, callsAfterAttach = 0, attachSeen = false
        let tools = AccountlessMountSystemTools { tool, arguments, _ in
            if attachSeen { callsAfterAttach += 1 }
            if tool == .hdiutil, arguments == ["info", "-plist"] { return try self.emptyInventory() }
            if tool == .lsof { return self.result("p\(getpid())\nf\(descriptor)\n") }
            if tool == .hdiutil, arguments.first == "attach" {
                attachSeen = true
                if pending { throw AccountlessDiskError.systemOperationPending }
                let attempts = try journal.mountAttempts().existing()
                XCTAssertEqual(attempts.count, 2)
                XCTAssertNotNil(try attempts[0].completion())
                return self.result("", code: 1)
            }
            XCTFail("unexpected command"); throw AccountlessDiskError.commandFailed
        }
        let stager = AccountlessOfflineStager(journal: journal, tools: tools, image: image,
            imageDescriptor: descriptor, validateOwnership: {})
        do { try await stager.stage(payloadDirectory: f.installation.destination); XCTFail("expected pending client") }
        catch { XCTAssertEqual(error as? AccountlessDiskError, .systemOperationPending) }
        XCTAssertEqual(callsAfterAttach, 0)
        XCTAssertNil(try journal.mountAttempts().existing()[0].completion())
        // The root authority layer separately excludes recovery until the old
        // child exits; this fixture now represents its terminal, detached state.
        pending = false; attachSeen = false
        do { try await stager.stage(payloadDirectory: f.installation.destination); XCTFail("second attach should fail") }
        catch { XCTAssertEqual(error as? AccountlessDiskError, .commandFailed) }
        let attempts = try journal.mountAttempts().existing()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(try attempts.allSatisfy { try $0.completion() != nil })
    }

    private func emptyInventory() throws -> SandboxProcessResult {
        .init(exitCode: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: ["images": []], format: .xml, options: 0),
            standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
    }
    private func result(_ output: String, code: Int32 = 0) -> SandboxProcessResult {
        .init(exitCode: code, standardOutput: Data(output.utf8), standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
    }
}
