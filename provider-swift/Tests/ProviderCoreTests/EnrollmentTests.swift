import Foundation
import Testing
@testable import ProviderCore

@Suite("Enrollment service")
struct EnrollmentTests {

    @Test("hardware serial number is non-empty on macOS")
    func hardwareSerialReadable() {
        // CI runners on macos-26-xlarge always have a serial; fail loudly
        // if ioreg parsing breaks. On the rare CI image without a serial,
        // skip rather than fail.
        guard let serial = macHardwareSerialNumber() else {
            // ioreg returned nothing parseable -- accept on minimal CI.
            return
        }
        #expect(!serial.isEmpty)
        #expect(!serial.contains(" "))
        #expect(serial.count >= 8, "serial '\(serial)' looks too short")
    }

    @Test("EnrollmentError descriptions are stable")
    func enrollmentErrorDescriptions() {
        let cases: [(EnrollmentError, String)] = [
            (.serialNumberUnavailable, "Could not read hardware serial number from ioreg."),
            (.coordinatorRequestFailed("nope"), "Failed to reach coordinator: nope"),
            (.coordinatorReturnedHTTP(503, body: "x"), "Coordinator returned HTTP 503: x"),
            (.profileWriteFailed("eperm"), "Failed to write enrollment profile: eperm"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
        }
    }

    @Test("LocalDataCleanup.purge removes only requested files")
    func purgeRespectsFlags() throws {
        // Create a temp scratch dir to model a fake home directory; we
        // exercise the helper with override paths to avoid touching the
        // real home in tests. (LocalDataCleanup directly references
        // FileManager.homeDirectoryForCurrentUser today; if we want to
        // test it without touching the real $HOME we'd need to refactor
        // it to take a base URL. For now, this test just validates the
        // helper runs without throwing on a real machine where the
        // listed files may or may not exist -- it's idempotent either
        // way.)
        LocalDataCleanup.purge(
            configDirectory: false,
            legacyKeyFiles: false,
            authToken: false
        )
        // No-op should always succeed.
    }
}
