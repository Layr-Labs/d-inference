import Darwin
import XCTest
@testable import SandboxRuntimeVZ

final class SandboxProcessSecurityContextTests: XCTestCase {
    private func context(uid: UInt32 = 501, effectiveUID: UInt32 = 501,
                         status: Int32 = 0, sessionID: UInt32 = 42, attributes: UInt32 = 0x10,
                         auditStatus: Int32 = 0, auditUID: UInt32? = 501) -> SandboxProcessSecurityContextSnapshot {
        .init(realUID: uid, effectiveUID: effectiveUID, sessionStatus: status, sessionID: sessionID,
              sessionAttributes: attributes, auditStatus: auditStatus, auditUID: auditUID)
    }

    func testAuthenticatedGUIAndLocalTerminalContextsAreAccepted() {
        for attributes in [UInt32(0x10), 0x30] {
            let snapshot = context(attributes: attributes)
            XCTAssertTrue(snapshot.isUsableGUISession)
            XCTAssertEqual(SandboxHostInspector.aquaSessionCheck(context: snapshot, required: true).status, .pass)
        }
    }

    func testBSDIdentitySwitchDoesNotEstablishTheAuditUsersGUIContext() {
        XCTAssertFalse(context(uid: 430, effectiveUID: 430).isUsableGUISession)
        XCTAssertFalse(context(effectiveUID: 0).isUsableGUISession)
        XCTAssertFalse(context(uid: 0, effectiveUID: 0, auditUID: 0).isUsableGUISession)
    }

    func testSSHAndSystemSessionsFailEvenIfAnotherUserHasAConsole() {
        for attributes in [UInt32(0), 1, 0x5020, 0x1010, 0x11] {
            let snapshot = context(attributes: attributes)
            let check = SandboxHostInspector.aquaSessionCheck(context: snapshot, required: true)
            XCTAssertFalse(snapshot.isUsableGUISession)
            XCTAssertEqual(check.id, "aqua_session")
            XCTAssertEqual(check.status, .failure)
        }
    }

    func testFailedOrIncompleteSecurityReadsFailClosed() {
        for snapshot in [context(status: -1), context(sessionID: 0), context(sessionID: .max),
                         context(auditStatus: -1), context(auditUID: nil), context(auditUID: UInt32.max)] {
            XCTAssertFalse(snapshot.isUsableGUISession)
        }
    }

    func testOptionalInspectionReportsWarningForUnsupportedContext() {
        XCTAssertEqual(SandboxHostInspector.aquaSessionCheck(context: context(attributes: 1), required: false).status, .warning)
    }

    func testCurrentProcessQueryUsesItsActualBSDIdentityWithoutRequiringGUI() {
        let snapshot = SandboxProcessSecurityContextSnapshot.capture()
        XCTAssertEqual(snapshot.realUID, getuid())
        XCTAssertEqual(snapshot.effectiveUID, geteuid())
        if snapshot.auditStatus != 0 { XCTAssertNil(snapshot.auditUID) }
    }
}
