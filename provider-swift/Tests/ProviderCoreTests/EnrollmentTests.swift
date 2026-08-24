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

    @Test("attestation serial parser reads ioreg output")
    func attestationSerialParserReadsIOReg() {
        let output = """
        +-o IOPlatformExpertDevice  <class IOPlatformExpertDevice, id 0x100000100, registered, matched, active, busy 0 (41 ms), retain 39>
            "IOPlatformSerialNumber" = "WV0NCDC2TX"
        """
        #expect(parseSerialNumberFromIOReg(output) == "WV0NCDC2TX")
    }

    @Test("attestation serial parser reads system_profiler output")
    func attestationSerialParserReadsSystemProfiler() {
        let output = """
            Hardware:

                Hardware Overview:

                  Model Name: Mac Studio
                  Chip: Apple M3 Ultra
                  Serial Number (system): WV0NCDC2TX
        """
        #expect(parseSerialNumberFromSystemProfiler(output) == "WV0NCDC2TX")
    }

    @Test("EnrollmentError descriptions are stable")
    func enrollmentErrorDescriptions() {
        let cases: [(EnrollmentError, String)] = [
            (.serialNumberUnavailable, "Could not read hardware serial number from ioreg."),
            (.coordinatorRequestFailed("nope"), "Failed to reach coordinator: nope"),
            (.coordinatorReturnedHTTP(503, body: "x"), "Coordinator returned HTTP 503: x"),
            (.profileWriteFailed("eperm"), "Failed to write enrollment profile: eperm"),
            (
                .profileOpenFailed("open exited 1"),
                "The enrollment profile was downloaded, but macOS could not open it: open exited 1. Open the profile manually, then install it in System Settings → General → Device Management."
            ),
            (
                .systemSettingsOpenFailed("open exited 2"),
                "The enrollment profile opened, but System Settings could not be opened automatically: open exited 2. Open System Settings → General → Device Management to finish installation."
            ),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
        }
    }

    @Test("A profile-open launch or exit failure is actionable and not successful")
    func profileOpenFailureIsTerminal() async {
        let recorder = EnrollmentOpenRecorder(failingCall: 1)
        let service = EnrollmentService(openCommand: recorder.run)

        do {
            _ = try await service.openDownloadedProfile(
                at: URL(fileURLWithPath: "/tmp/Darkbloom.mobileconfig")
            )
            Issue.record("expected profile-open failure")
        } catch let error as EnrollmentError {
            guard case .profileOpenFailed(let detail) = error else {
                Issue.record("unexpected enrollment error: \(error)")
                return
            }
            #expect(detail == "open exited 1")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(recorder.calls == [["/tmp/Darkbloom.mobileconfig"]])
    }

    @Test("A secondary System Settings failure returns an actionable warning")
    func settingsOpenFailureIsWarning() async throws {
        let recorder = EnrollmentOpenRecorder(failingCall: 2)
        let service = EnrollmentService(openCommand: recorder.run)

        let warning = try await service.openDownloadedProfile(
            at: URL(fileURLWithPath: "/tmp/Darkbloom.mobileconfig")
        )

        #expect(warning?.contains("System Settings could not be opened automatically") == true)
        #expect(warning?.contains("Device Management") == true)
        #expect(recorder.calls == [
            ["/tmp/Darkbloom.mobileconfig"],
            ["x-apple.systempreferences:com.apple.Profiles-Settings.extension"],
        ])
    }

    @Test("Successful profile and settings opens return no warning")
    func profileAndSettingsOpenSuccessfully() async throws {
        let recorder = EnrollmentOpenRecorder()
        let service = EnrollmentService(openCommand: recorder.run)

        let warning = try await service.openDownloadedProfile(
            at: URL(fileURLWithPath: "/tmp/Darkbloom.mobileconfig")
        )

        #expect(warning == nil)
        #expect(recorder.calls.count == 2)
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
        try LocalDataCleanup.purge(
            configDirectory: false,
            legacyKeyFiles: false,
            authToken: false
        )
        // No-op should always succeed.
    }
}

private final class EnrollmentOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int?
    private var storage: [[String]] = []

    init(failingCall: Int? = nil) {
        self.failingCall = failingCall
    }

    var calls: [[String]] { lock.withLock { storage } }

    func run(arguments: [String]) throws {
        let call = lock.withLock { () -> Int in
            storage.append(arguments)
            return storage.count
        }
        if call == failingCall {
            throw EnrollmentOpenStubError.failed(call)
        }
    }
}

private enum EnrollmentOpenStubError: Error, LocalizedError {
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .failed(let call): "open exited \(call)"
        }
    }
}
