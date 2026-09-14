import Darwin
import XCTest
@testable import SandboxGuestRuntime

final class GuestTenantQualificationTests: XCTestCase {
    func testCredentialsRejectHostRootWrongGroupsAndNonvirtualizedExecution() throws {
        for groups: [gid_t] in [[], [2001]] {
            XCTAssertNoThrow(try GuestTenantQualification.Credentials(uid: 2001, effectiveUID: 2001,
                gid: 2001, effectiveGID: 2001, groups: groups, virtualized: 1).validate())
        }
        for (uid, euid, gid, egid, groups, virtualized): (uid_t, uid_t, gid_t, gid_t, [gid_t], Int32) in [
            (0,0,0,0,[],1), (501,501,20,20,[],1), (2001,0,2001,2001,[],1),
            (2001,2001,2001,20,[],1), (2001,2001,2001,2001,[20],1), (2001,2001,2001,2001,[],0)] {
            XCTAssertThrowsError(try GuestTenantQualification.Credentials(uid: uid, effectiveUID: euid,
                gid: gid, effectiveGID: egid, groups: groups, virtualized: virtualized).validate())
        }
        if getuid() != 2001 { XCTAssertThrowsError(try GuestTenantQualification.run()) }
    }

    func testMissingPathsAndOtherIOErrorsCannotCountAsPermissionDenial() {
        for error in [EACCES, EPERM] { XCTAssertTrue(GuestTenantQualification.permissionDenied(error)) }
        for error in [ENOENT, ELOOP, ENXIO, EIO, EINVAL, Int32(0)] {
            XCTAssertFalse(GuestTenantQualification.permissionDenied(error))
        }
        for path in ["disk0", "rdisk0", "disk1s2", "rdisk3s1s1"] { XCTAssertTrue(GuestTenantQualification.isDiskName(path)) }
        for path in ["disk", "diskx", "rdisk", "disk1/other", "disk1\n", "random", "disk1.alias"] {
            XCTAssertFalse(GuestTenantQualification.isDiskName(path))
        }
    }
}
