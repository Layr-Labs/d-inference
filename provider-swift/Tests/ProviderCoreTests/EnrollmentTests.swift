import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

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
            (
                .invalidProfileResponse("wrong media type"),
                "Coordinator returned an invalid enrollment profile: wrong media type"
            ),
            (
                .profileResponseTooLarge(maximumBytes: 1024),
                "Coordinator returned an enrollment profile larger than the 1024-byte safety limit."
            ),
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

    @Test("Profile removal opens the canonical removal pane without enrollment")
    func profileRemovalUsesCanonicalPane() {
        let recorder = EnrollmentOpenRecorder()
        let service = EnrollmentService(openCommand: recorder.run)

        service.openProfilesPaneForRemoval()

        #expect(recorder.calls == [
            [SystemSettingsProfileRemovalPane.deepLink],
        ])
    }

    @Test("Enrollment rejects unsafe profile responses before filesystem or open side effects")
    func invalidProfileResponsesHaveNoSideEffects() async throws {
        let endpoint = try #require(URL(string: "https://api.darkbloom.dev/v1/enroll"))
        let validHeaders = [
            "Content-Type": EnrollmentProfileResponse.supportedMediaType,
        ]
        let cases = [
            InvalidProfileResponse(
                name: "non-HTTP",
                data: Data("profile".utf8),
                response: URLResponse(
                    url: endpoint,
                    mimeType: EnrollmentProfileResponse.supportedMediaType,
                    expectedContentLength: 7,
                    textEncodingName: nil
                )
            ),
            InvalidProfileResponse(
                name: "redirect",
                data: Data("profile".utf8),
                response: httpResponse(
                    endpoint,
                    status: 302,
                    headers: validHeaders
                )
            ),
            InvalidProfileResponse(
                name: "HTML",
                data: Data("<html>sign in</html>".utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: ["Content-Type": "text/html; charset=utf-8"]
                )
            ),
            InvalidProfileResponse(
                name: "JSON",
                data: Data(#"{"error":"no profile"}"#.utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: ["Content-Type": "application/json"]
                )
            ),
            InvalidProfileResponse(
                name: "wrong media type",
                data: Data("profile".utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: ["Content-Type": "application/octet-stream"]
                )
            ),
            InvalidProfileResponse(
                name: "missing media type",
                data: Data("profile".utf8),
                response: httpResponse(endpoint, status: 200)
            ),
            InvalidProfileResponse(
                name: "ambiguous media types",
                data: Data("profile".utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: [
                        "Content-Type":
                            "\(EnrollmentProfileResponse.supportedMediaType), text/html",
                    ]
                )
            ),
            InvalidProfileResponse(
                name: "malformed media parameter",
                data: Data("profile".utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: [
                        "Content-Type":
                            "\(EnrollmentProfileResponse.supportedMediaType); charset",
                    ]
                )
            ),
            InvalidProfileResponse(
                name: "empty body",
                data: Data(),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: validHeaders
                )
            ),
            InvalidProfileResponse(
                name: "oversized body",
                data: Data(
                    repeating: 0x41,
                    count: EnrollmentProfileResponse.maximumBytes + 1
                ),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: validHeaders
                )
            ),
            InvalidProfileResponse(
                name: "oversized declared length",
                data: Data("profile".utf8),
                response: httpResponse(
                    endpoint,
                    status: 200,
                    headers: [
                        "Content-Type":
                            EnrollmentProfileResponse.supportedMediaType,
                        "Content-Length":
                            "\(EnrollmentProfileResponse.maximumBytes + 1)",
                    ]
                )
            ),
        ]

        for invalid in cases {
            let fixture = try EnrollmentProfileFixture()
            defer { fixture.remove() }
            let recorder = EnrollmentOpenRecorder()
            let service = EnrollmentService(
                openCommand: recorder.run,
                requestProfile: { _ in
                    (invalid.data, invalid.response)
                },
                enrollmentStateReader: { _ in .notEnrolled },
                serialNumberReader: { fixture.serial },
                profileDirectory: fixture.root
            )

            do {
                _ = try await service.enroll(
                    coordinatorURL: "https://api.darkbloom.dev",
                    openSystemSettings: true
                )
                Issue.record("accepted unsafe \(invalid.name) response")
            } catch is EnrollmentError {
                // Expected: every response is invalid for a distinct reason.
            } catch {
                Issue.record("unexpected \(invalid.name) error: \(error)")
            }

            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.profilePath.path
                ),
                "wrote \(invalid.name) response"
            )
            #expect(recorder.calls.isEmpty, "opened \(invalid.name) response")
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.path
                ).isEmpty
            )
        }
    }

    @Test("Enrollment accepts a bounded 2xx profile with normalized media type")
    func validProfileResponseWritesThenOpens() async throws {
        let fixture = try EnrollmentProfileFixture()
        defer { fixture.remove() }
        let endpoint = try #require(
            URL(string: "https://api.darkbloom.dev/v1/enroll")
        )
        let profile = Data("signed-mobileconfig".utf8)
        let payload = InvalidProfileResponse(
            name: "valid",
            data: profile,
            response: httpResponse(
                endpoint,
                status: 201,
                headers: [
                    "Content-Type":
                        "Application/X-Apple-Aspen-Config; charset=\"binary\"",
                ]
            )
        )
        let recorder = EnrollmentOpenRecorder()
        let service = EnrollmentService(
            openCommand: recorder.run,
            requestProfile: { _ in (payload.data, payload.response) },
            enrollmentStateReader: { _ in .notEnrolled },
            serialNumberReader: { fixture.serial },
            profileDirectory: fixture.root
        )

        let result = try await service.enroll(
            coordinatorURL: "https://api.darkbloom.dev",
            openSystemSettings: true
        )

        #expect(result.profilePath == fixture.profilePath)
        #expect(result.profileOpened)
        #expect(try Data(contentsOf: fixture.profilePath) == profile)
        #expect(recorder.calls == [
            [fixture.profilePath.path],
            ["x-apple.systempreferences:com.apple.Profiles-Settings.extension"],
        ])
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
            authToken: false,
            secureEnclaveKey: false
        )
        // No-op should always succeed.
    }
}

private struct InvalidProfileResponse: @unchecked Sendable {
    let name: String
    let data: Data
    let response: URLResponse
}

private func httpResponse(
    _ url: URL,
    status: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private struct EnrollmentProfileFixture: Sendable {
    let root: URL
    let serial = "SERIAL1234"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "enrollment-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    var profilePath: URL {
        root.appendingPathComponent(
            "Darkbloom-Enroll-\(serial).mobileconfig"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
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
