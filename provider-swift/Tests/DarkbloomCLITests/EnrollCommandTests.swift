import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("enroll output")
struct EnrollCommandTests {
    private let profileURL = URL(fileURLWithPath: "/tmp/Darkbloom-Enroll-C02TEST.mobileconfig")

    @Test("--json and --no-open flags parse without changing human defaults")
    func flagsParse() throws {
        let machine = try #require(
            try Darkbloom.parseAsRoot(["enroll", "--json", "--no-open"]) as? Enroll
        )
        #expect(machine.json)
        #expect(machine.noOpen)

        let human = try #require(try Darkbloom.parseAsRoot(["enroll"]) as? Enroll)
        #expect(!human.json)
        #expect(!human.noOpen)
    }

    @Test("schema 1 JSON encodings are byte-stable golden documents")
    func jsonGoldenDocuments() throws {
        let already = EnrollmentCommandResult(
            serviceResult: EnrollmentResult(
                serialNumber: "C02TEST",
                profilePath: URL(fileURLWithPath: "/dev/null"),
                alreadyEnrolled: true,
                profileOpened: false
            )
        )
        let opened = EnrollmentCommandResult(
            serviceResult: EnrollmentResult(
                serialNumber: "C02TEST",
                profilePath: profileURL,
                alreadyEnrolled: false,
                profileOpened: true
            )
        )
        let downloaded = EnrollmentCommandResult(
            serviceResult: EnrollmentResult(
                serialNumber: "C02TEST",
                profilePath: profileURL,
                alreadyEnrolled: false,
                profileOpened: false
            )
        )

        #expect(try EnrollmentJSONRenderer.render(already) ==
            #"{"schema":1,"serial_number":"C02TEST","status":"already_enrolled"}"#)
        #expect(try EnrollmentJSONRenderer.render(opened) ==
            #"{"profile_path":"/tmp/Darkbloom-Enroll-C02TEST.mobileconfig","schema":1,"serial_number":"C02TEST","status":"profile_opened"}"#)
        #expect(try EnrollmentJSONRenderer.render(downloaded) ==
            #"{"profile_path":"/tmp/Darkbloom-Enroll-C02TEST.mobileconfig","schema":1,"serial_number":"C02TEST","status":"profile_downloaded"}"#)
    }

    @Test("schema keys and optional profile path are exact")
    func jsonSchemaKeysAreExact() throws {
        let already = try jsonObject(alreadyEnrolled: true, openedProfile: true)
        #expect(Set(already.keys) == ["schema", "status", "serial_number"])
        #expect((already["schema"] as? NSNumber)?.intValue == 1)
        #expect(already["status"] as? String == "already_enrolled")
        #expect(already["serial_number"] as? String == "C02TEST")

        let opened = try jsonObject(alreadyEnrolled: false, openedProfile: true)
        #expect(Set(opened.keys) == ["schema", "status", "serial_number", "profile_path"])
        #expect(opened["status"] as? String == "profile_opened")
        #expect(opened["profile_path"] as? String == profileURL.path)

        let downloaded = try jsonObject(alreadyEnrolled: false, openedProfile: false)
        #expect(downloaded["status"] as? String == "profile_downloaded")
    }

    @Test("human output preserves the established already-enrolled text")
    func humanAlreadyEnrolledGolden() async throws {
        let command = try parsedEnroll([])
        var stdout = ""
        try await awaitCommand(command, result: EnrollmentResult(
            serialNumber: "C02TEST",
            profilePath: URL(fileURLWithPath: "/dev/null"),
            alreadyEnrolled: true,
            profileOpened: false
        ), stdout: &stdout)

        #expect(stdout == """
            Darkbloom Device Attestation Enrollment
            Coordinator: https://api.example.test

              ✓ Already enrolled — no action needed.
              Verify with: darkbloom doctor
            """ + "\n")
    }

    @Test("human --no-open output preserves the established instructions")
    func humanDownloadedGolden() async throws {
        let command = try parsedEnroll(["--no-open"])
        var stdout = ""
        try await command.execute(
            coordinatorURL: "wss://api.example.test",
            enroll: { coordinatorURL, openSystemSettings in
                #expect(coordinatorURL == "wss://api.example.test")
                #expect(!openSystemSettings)
                return EnrollmentResult(
                    serialNumber: "C02TEST",
                    profilePath: URL(fileURLWithPath: "/tmp/Darkbloom-Enroll-C02TEST.mobileconfig"),
                    alreadyEnrolled: false,
                    profileOpened: false
                )
            },
            output: { stdout += $0 + "\n" },
            errorOutput: { _ in }
        )

        #expect(stdout == """
            Darkbloom Device Attestation Enrollment
            Coordinator: https://api.example.test

              → Device serial:  C02TEST
              → Profile saved:  /tmp/Darkbloom-Enroll-C02TEST.mobileconfig

              Install the profile manually:
                open /tmp/Darkbloom-Enroll-C02TEST.mobileconfig

            After installing, verify with: darkbloom doctor
            """ + "\n")
    }

    @Test("human default output preserves the established opened-profile text")
    func humanOpenedGolden() async throws {
        let command = try parsedEnroll([])
        var stdout = ""
        try await command.execute(
            coordinatorURL: "https://api.example.test",
            enroll: { _, openSystemSettings in
                #expect(openSystemSettings)
                return EnrollmentResult(
                    serialNumber: "C02TEST",
                    profilePath: URL(fileURLWithPath: "/tmp/Darkbloom-Enroll-C02TEST.mobileconfig"),
                    alreadyEnrolled: false,
                    profileOpened: true
                )
            },
            output: { stdout += $0 + "\n" },
            errorOutput: { _ in }
        )

        #expect(stdout == """
            Darkbloom Device Attestation Enrollment
            Coordinator: https://api.example.test

              → Device serial:  C02TEST
              → Profile saved:  /tmp/Darkbloom-Enroll-C02TEST.mobileconfig

              System Settings → Device Management is now open.
              Click Install on the Darkbloom profile and enter your password.

              This verifies:
                • SIP, Secure Boot, and system integrity
                • Your Secure Enclave is genuine Apple hardware
                • Device identity signed by Apple's Root CA

              Darkbloom CANNOT erase, lock, or control your Mac.
            After installing, verify with: darkbloom doctor
            """ + "\n")
    }

    @Test("JSON no-open uses the injected service without banners or machine mutation")
    func injectedJSONNoOpenSmoke() async throws {
        let command = try parsedEnroll(["--json", "--no-open"])
        var stdout: [String] = []
        var stderr: [String] = []

        try await command.execute(
            coordinatorURL: "wss://api.example.test",
            enroll: { coordinatorURL, openSystemSettings in
                #expect(coordinatorURL == "wss://api.example.test")
                #expect(!openSystemSettings)
                return EnrollmentResult(
                    serialNumber: "C02TEST",
                    profilePath: URL(fileURLWithPath: "/tmp/Darkbloom-Enroll-C02TEST.mobileconfig"),
                    alreadyEnrolled: false,
                    profileOpened: false
                )
            },
            output: { stdout.append($0) },
            errorOutput: { stderr.append($0) }
        )

        #expect(stdout == [
            #"{"profile_path":"/tmp/Darkbloom-Enroll-C02TEST.mobileconfig","schema":1,"serial_number":"C02TEST","status":"profile_downloaded"}"#,
        ])
        #expect(stderr.isEmpty)
    }

    @Test("profile_opened follows actual service evidence, not the requested open mode")
    func actualOpenResultDeterminesStatus() async throws {
        let command = try parsedEnroll(["--json"])
        var stdout: [String] = []

        try await command.execute(
            coordinatorURL: "https://api.example.test",
            enroll: { _, requestedOpen in
                #expect(requestedOpen)
                return EnrollmentResult(
                    serialNumber: "C02TEST",
                    profilePath: URL(fileURLWithPath: "/tmp/Darkbloom.mobileconfig"),
                    alreadyEnrolled: false,
                    profileOpened: false
                )
            },
            output: { stdout.append($0) },
            errorOutput: { _ in }
        )

        #expect(stdout == [
            #"{"profile_path":"/tmp/Darkbloom.mobileconfig","schema":1,"serial_number":"C02TEST","status":"profile_downloaded"}"#,
        ])
    }

    @Test("secondary System Settings warnings remain machine-readable")
    func settingsWarningIsRendered() throws {
        let result = EnrollmentCommandResult(serviceResult: EnrollmentResult(
            serialNumber: "C02TEST",
            profilePath: profileURL,
            alreadyEnrolled: false,
            profileOpened: true,
            openWarning: "Open Device Management manually."
        ))

        #expect(try EnrollmentJSONRenderer.render(result) ==
            #"{"profile_path":"/tmp/Darkbloom-Enroll-C02TEST.mobileconfig","schema":1,"serial_number":"C02TEST","status":"profile_opened","warning":"Open Device Management manually."}"#)
        #expect(EnrollmentHumanRenderer.completion(result).contains(
            "Warning: Open Device Management manually."
        ))
    }

    @Test("JSON enrollment failure is stderr-only and exits failure")
    func jsonFailureIsStderrOnly() async throws {
        let command = try parsedEnroll(["--json"])
        var stdout: [String] = []
        var stderr: [String] = []

        do {
            try await command.execute(
                coordinatorURL: "https://api.example.test",
                enroll: { _, _ in
                    throw EnrollmentError.coordinatorRequestFailed("offline")
                },
                output: { stdout.append($0) },
                errorOutput: { stderr.append($0) }
            )
            Issue.record("expected enrollment failure")
        } catch let error as ExitCode {
            #expect(error == .failure)
        }

        #expect(stdout.isEmpty)
        #expect(stderr == ["Failed to reach coordinator: offline"])
    }

    private func parsedEnroll(_ arguments: [String]) throws -> Enroll {
        try #require(Darkbloom.parseAsRoot(["enroll"] + arguments) as? Enroll)
    }

    private func jsonObject(
        alreadyEnrolled: Bool,
        openedProfile: Bool
    ) throws -> [String: Any] {
        let result = EnrollmentCommandResult(
            serviceResult: EnrollmentResult(
                serialNumber: "C02TEST",
                profilePath: profileURL,
                alreadyEnrolled: alreadyEnrolled,
                profileOpened: openedProfile
            )
        )
        let rendered = try EnrollmentJSONRenderer.render(result)
        return try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
    }

    private func awaitCommand(
        _ command: Enroll,
        result: EnrollmentResult,
        stdout: inout String
    ) async throws {
        try await command.execute(
            coordinatorURL: "https://api.example.test",
            enroll: { _, openSystemSettings in
                #expect(openSystemSettings)
                return result
            },
            output: { stdout += $0 + "\n" },
            errorOutput: { _ in }
        )
    }
}
