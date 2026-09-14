import Foundation
import SandboxGuestProtocol
@testable import SandboxRuntimeLume
import XCTest

final class LumeNativeQualificationDriverTests: XCTestCase {
    func testChecksBothBootsAndPersistedMarkerWithDistinctDurableCommandIDs() async throws {
        let harness = LumeNativeQualificationTestHarness()
        let qualificationID = UUID(), cloneID = UUID()
        let result = try await LumeNativeQualificationDriver(qualificationID: qualificationID, cloneInstallationID: cloneID, io: harness.io).run()
        XCTAssertEqual(result.initialBootID, harness.firstBoot)
        XCTAssertEqual(result.restartedBootID, harness.secondBoot)
        let state = await harness.snapshot()
        XCTAssertEqual(state.commands.count, 4)
        XCTAssertEqual(Set(state.commands.map(\.idempotencyKey)).count, 4)
        XCTAssertEqual(state.events, ["probe-before", "boot-before", "mkdir-before", "uploadBegin-before", "uploadChunk-before",
            "uploadCommit-before", "download-before", "restart", "boot-after", "probe-after", "download-after"])
        let replay = LumeNativeQualificationTestHarness()
        _ = try await LumeNativeQualificationDriver(qualificationID: qualificationID, cloneInstallationID: cloneID, io: replay.io).run()
        let again = await replay.snapshot()
        XCTAssertEqual(state.commands.map(\.idempotencyKey), again.commands.map(\.idempotencyKey))
        XCTAssertEqual(result.markerSHA256.count, 64)
    }

    func testIncompleteCommandsAndFileAcknowledgmentsCannotProduceQualification() async throws {
        for fault in ["probe-output", "exit-code", "stderr", "truncated", "timeout", "invalid-boot", "response-id",
                      "requires-stop", "reported-error", "wrong-transfer", "upload-offset", "download-hash", "missing-revision"] {
            let harness = LumeNativeQualificationTestHarness(fault: fault)
            do {
                _ = try await LumeNativeQualificationDriver(qualificationID: UUID(), cloneInstallationID: UUID(), io: harness.io).run()
                XCTFail("accepted \(fault)")
            } catch {}
            let state = await harness.snapshot()
            XCTAssertFalse(state.events.contains("restart"), fault)
        }
    }

    func testSameBootLostMarkerAndCancelledRestartFailAfterFirstBootChecks() async throws {
        for fault in ["same-boot", "lost-marker", "restart-cancelled"] {
            let harness = LumeNativeQualificationTestHarness(fault: fault)
            do {
                _ = try await LumeNativeQualificationDriver(qualificationID: UUID(), cloneInstallationID: UUID(), io: harness.io).run()
                XCTFail("accepted \(fault)")
            } catch {}
            let state = await harness.snapshot()
            XCTAssertEqual(state.events.filter { $0 == "restart" }.count, 1)
            XCTAssertTrue(state.events.contains("download-before"))
        }
    }

    func testObservedFilesAndFakeRunningMetadataDoNotCreateNativeRuntimeAuthority() async throws {
        let fixture = try await LumeQualificationCleanupFixture(); defer { fixture.remove() }
        try fixture.prepareMaterials(); try fixture.setRunning(true)
        let observation = try await fixture.observe()
        do { _ = try await fixture.base.runtime.runNativeQualification(observation); XCTFail("unmanaged VM accepted") } catch {}
        XCTAssertFalse(fixture.capability.nativeChecksAttempted)
    }
}
