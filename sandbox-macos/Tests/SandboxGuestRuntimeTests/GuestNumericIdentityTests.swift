import Darwin
@testable import SandboxGuestRuntime
import XCTest

final class GuestNumericIdentityTests: XCTestCase {
    func testOnlySuccessfulAbsenceOfBothFixedIdentitiesIsAccepted() throws {
        var checked: [UInt32] = []
        let absent: GuestNumericIdentity.Lookup = { id, _ in
            checked.append(id)
            return .init(status: 0, found: false)
        }
        try GuestNumericIdentity.validate(userLookup: absent, groupLookup: absent)
        XCTAssertEqual(checked, [2001, 2001])
        XCTAssertThrowsError(try GuestNumericIdentity.validate(
            userLookup: { _, _ in .init(status: 0, found: true) }, groupLookup: absent)) {
            XCTAssertEqual($0 as? GuestNumericIdentityError, .userRegistered)
        }
        XCTAssertThrowsError(try GuestNumericIdentity.validate(userLookup: absent,
            groupLookup: { _, _ in .init(status: 0, found: true) })) {
            XCTAssertEqual($0 as? GuestNumericIdentityError, .groupRegistered)
        }
    }

    func testLookupFailuresCannotMasqueradeAsAbsence() {
        for status in [EIO, EACCES, ENOENT, EINTR] {
            for userFails in [true, false] {
                let failure: GuestNumericIdentity.Lookup = { _, _ in .init(status: status, found: false) }
                let absent: GuestNumericIdentity.Lookup = { _, _ in .init(status: 0, found: false) }
                XCTAssertThrowsError(try GuestNumericIdentity.validate(
                    userLookup: userFails ? failure : absent, groupLookup: userFails ? absent : failure)) {
                    XCTAssertEqual($0 as? GuestNumericIdentityError, .lookupFailed(status))
                }
            }
        }
    }

    func testReentrantLookupRetriesWithinFixedBufferBound() throws {
        var sizes: [Int] = []
        try GuestNumericIdentity.validate(userLookup: { _, buffer in
            sizes.append(buffer.count)
            return .init(status: buffer.count < 65536 ? ERANGE : 0, found: false)
        }, groupLookup: { _, _ in .init(status: 0, found: false) })
        XCTAssertEqual(sizes, [16384, 32768, 65536])
        sizes.removeAll()
        XCTAssertThrowsError(try GuestNumericIdentity.validate(userLookup: { _, buffer in
            sizes.append(buffer.count)
            return .init(status: ERANGE, found: false)
        }, groupLookup: { _, _ in .init(status: 0, found: false) })) {
            XCTAssertEqual($0 as? GuestNumericIdentityError, .lookupExceedsBound)
        }
        XCTAssertEqual(sizes.last, GuestNumericIdentity.maximumBufferBytes)
        XCTAssertEqual(sizes.count, 7)
    }

    func testIdentityRegistrationBetweenCommandsIsDetectedWithoutCaching() throws {
        var registered = false
        let lookup: GuestNumericIdentity.Lookup = { _, _ in .init(status: 0, found: registered) }
        try GuestNumericIdentity.validate(userLookup: lookup, groupLookup: lookup)
        registered = true
        XCTAssertThrowsError(try GuestNumericIdentity.validate(userLookup: lookup, groupLookup: lookup)) {
            XCTAssertEqual($0 as? GuestNumericIdentityError, .userRegistered)
        }
    }

    func testNativeReentrantBindingsRecognizeExistingSystemIdentities() {
        var buffer = [CChar](repeating: 0, count: GuestNumericIdentity.maximumBufferBytes)
        let user = buffer.withUnsafeMutableBufferPointer { GuestNumericIdentity.userRecord(0, $0) }
        let group = buffer.withUnsafeMutableBufferPointer { GuestNumericIdentity.groupRecord(0, $0) }
        XCTAssertEqual(user.status, 0)
        XCTAssertTrue(user.found)
        XCTAssertEqual(group.status, 0)
        XCTAssertTrue(group.found)
    }

    func testWorkerCannotChangeIdentityFromUnprivilegedHostTest() throws {
        guard getuid() != 0 else { throw XCTSkip("worker guard test is unprivileged only") }
        let uid = getuid(), gid = getgid()
        XCTAssertThrowsError(try GuestTenantWorker.run(arguments: ["tenant-cleanup"]))
        XCTAssertThrowsError(try GuestTenantWorker.run(arguments: ["tenant-exec", "/workspace", "invalid"]))
        XCTAssertEqual(getuid(), uid)
        XCTAssertEqual(geteuid(), uid)
        XCTAssertEqual(getgid(), gid)
    }
}
