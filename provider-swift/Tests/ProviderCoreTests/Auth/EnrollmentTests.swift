import CryptoKit
import Foundation
import Security
import Testing
@testable import ProviderCore

@Suite("Enrollment service")
struct EnrollmentTests {

    @Test("profile request authenticates and signs exact canonical UTF-8 bytes")
    func profileRequestProof() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let timestamp: Int64 = 1_791_072_000
        let message = Data(("darkbloom-mdm-enroll-v1\n"
            + "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
            + "\(publicKey)\n1791072000").utf8)
        let endpoint = URL(string: "https://coordinator.invalid/v1/enroll")!
        let request = try EnrollmentService.profileRequest(
            endpoint: endpoint, loadToken: { "abc" },
            loadSigner: { ProofSigner(key: key) },
            timestamp: timestamp)
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(fields.keys) == ["se_public_key", "timestamp", "signature"])
        #expect(fields["se_public_key"] as? String == publicKey)
        #expect((fields["timestamp"] as? NSNumber)?.int64Value == timestamp)
        let signatureBase64 = try #require(fields["signature"] as? String)
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: #require(Data(base64Encoded: signatureBase64)))
        #expect(key.publicKey.isValidSignature(signature, for: message))
    }

    @Test("profile request defaults to current Unix seconds and signs that timestamp")
    func profileRequestDefaultTimestamp() throws {
        let key = P256.Signing.PrivateKey()
        let before = Int64(Date().timeIntervalSince1970)
        let request = try EnrollmentService.profileRequest(
            endpoint: URL(string: "https://coordinator.invalid/v1/enroll")!,
            loadToken: { "abc" }, loadSigner: { ProofSigner(key: key) })
        let after = Int64(Date().timeIntervalSince1970)
        let body = try #require(request.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let timestamp = try #require((fields["timestamp"] as? NSNumber)?.int64Value)
        #expect(timestamp >= before)
        #expect(timestamp <= after)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let message = Data(("darkbloom-mdm-enroll-v1\n"
            + "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
            + "\(publicKey)\n\(timestamp)").utf8)
        let signatureBase64 = try #require(fields["signature"] as? String)
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: #require(Data(base64Encoded: signatureBase64)))
        #expect(key.publicKey.isValidSignature(signature, for: message))
    }

    @Test("profile request requires linked credentials before loading a key", arguments: [nil, ""] as [String?])
    func profileRequestRequiresCredentials(token: String?) {
        #expect(throws: EnrollmentError.self) {
            _ = try EnrollmentService.profileRequest(
                endpoint: URL(string: "https://coordinator.invalid/v1/enroll")!,
                loadToken: { token }, loadSigner: {
                    Issue.record("Missing credentials must not access the Secure Enclave")
                    throw ProofFailure.signing
                })
        }
    }

    @Test("profile request explains existing-key lookup failure without fallback")
    func profileRequestRequiresExistingKey() {
        #expect(throws: EnrollmentError.self) {
            _ = try EnrollmentService.profileRequest(
                endpoint: URL(string: "https://coordinator.invalid/v1/enroll")!,
                loadToken: { "abc" }, loadSigner: {
                    throw PersistentEnclaveKeyError.keyLookupFailed(status: errSecItemNotFound)
                })
        }
    }

    @Test("profile request propagates signing failure without an empty request")
    func profileRequestRequiresSignature() {
        #expect(throws: ProofFailure.signing) {
            _ = try EnrollmentService.profileRequest(
                endpoint: URL(string: "https://coordinator.invalid/v1/enroll")!,
                loadToken: { "abc" }, loadSigner: { FailingSigner() })
        }
    }

    @Test("macOS 27+ never requests an enrollment profile", arguments: [27, 28])
    func appAttestSetupSkipsProfile(macOSMajorVersion: Int) async throws {
        // An unusable coordinator and openSystemSettings=true exercise the
        // early exit before networking, profile creation or opening Settings.
        let service = EnrollmentService(
            checkEnrollment: { _ in
                Issue.record("App Attest guidance must not inspect MDM")
                return .checkFailed
            }, loadToken: {
                Issue.record("App Attest guidance must not load legacy credentials")
                return nil
            })
        let result = try await service.enroll(
            coordinatorURL: "http://127.0.0.1:1", openSystemSettings: true,
            macOSMajorVersion: macOSMajorVersion)
        guard case .appAttest = result else {
            Issue.record("App Attest setup unexpectedly returned an MDM profile")
            return
        }
    }

    @Test("legacy enrollment checks authoritative eligibility before install or already-enrolled success",
          arguments: [200, 403], [MDMEnrollmentState.enrolledDarkbloom(serverURL: "https://fixture.invalid/mdm"), .notEnrolled, .checkFailed])
    func legacyEligibility(status: Int, state: MDMEnrollmentState) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("enrollment-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let denial = "New providers require macOS 27 or later and coordinator-qualified App Attest."
        let payload = status == 200 ? MockCoordinator.defaultMobileConfig : Data(denial.utf8)
        let coordinator = MockCoordinator(mobileConfig: payload, enrollmentHTTPStatus: status)
        let base = try await coordinator.start()
        defer { Task { await coordinator.shutdown() } }
        let key = P256.Signing.PrivateKey()
        let service = EnrollmentService(
            checkEnrollment: { _ in state }, loadToken: { "fixture-token" },
            loadSigner: { ProofSigner(key: key) }, profileDirectory: directory)
        do {
            let result = try await service.enroll(
                coordinatorURL: base.absoluteString, openSystemSettings: false, macOSMajorVersion: 26)
            #expect(status == 200, "Copied/existing profiles must not bypass coordinator denial")
            guard case .mdm(let path, let alreadyEnrolled) = result else {
                Issue.record("Legacy enrollment returned App Attest guidance")
                return
            }
            #expect(alreadyEnrolled == state.isDarkbloom)
            if !alreadyEnrolled {
                #expect(try Data(contentsOf: path) == payload)
            }
        } catch let error as EnrollmentError {
            guard case .coordinatorReturnedHTTP(let code, let body) = error else { throw error }
            #expect(status == 403)
            #expect(code == 403)
            #expect(body == denial)
        }
        let captured = coordinator.snapshot()
        #expect(captured.enrollmentPosts.count == 1)
        #expect(captured.enrollmentAuthorizations == ["Bearer fixture-token"])
        let body = try #require(captured.enrollmentPosts.first)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["se_public_key"] as? String == key.publicKey.rawRepresentation.base64EncodedString())
        #expect(fields["signature"] as? String != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == (status == 200 && !state.isDarkbloom ? 1 : 0))
    }

    @Test("foreign MDM stays untouched without loading credentials")
    func foreignMDMIsPreserved() async {
        let service = EnrollmentService(
            checkEnrollment: { _ in .enrolledOtherMDM(serverURL: "https://company.invalid") },
            loadToken: {
                Issue.record("Foreign MDM must not attempt legacy enrollment")
                return nil
            })
        await #expect(throws: EnrollmentError.self) {
            _ = try await service.enroll(coordinatorURL: "http://127.0.0.1:1", macOSMajorVersion: 26)
        }
    }

    @Test("existing local profiles still require the grandfathered account and key", arguments: [false, true])
    func existingProfileRequiresIdentity(hasToken: Bool) async throws {
        let service = EnrollmentService(
            checkEnrollment: { _ in .enrolledDarkbloom(serverURL: "https://fixture.invalid") },
            loadToken: { hasToken ? "fixture-token" : nil }, loadSigner: {
                #expect(hasToken, "Missing credentials must fail before key access")
                throw PersistentEnclaveKeyError.keyLookupFailed(status: errSecItemNotFound)
            })
        do {
            _ = try await service.enroll(coordinatorURL: "http://127.0.0.1:1", macOSMajorVersion: 26)
            Issue.record("Local profile must not substitute for grandfathered identity")
        } catch let error as EnrollmentError {
            #expect(error.description.contains("macOS 27 or later"))
            #expect(error.description.contains("coordinator-qualified App Attest"))
            #expect(error.description.contains("grandfathered"))
        }
    }

    @Test("older macOS retains legacy setup", arguments: [14, 26])
    func olderMacOSUsesLegacySetup(macOSMajorVersion: Int) {
        #expect(!ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion))
    }

    @Test("attestation serial parser reads ioreg output")
    func attestationSerialParserReadsIOReg() {
        let output = """
        +-o IOPlatformExpertDevice  <class IOPlatformExpertDevice, id 0x100000100, registered, matched, active, busy 0 (41 ms), retain 39>
            "IOPlatformSerialNumber" = "TESTDEVICE01"
        """
        #expect(parseSerialNumberFromIOReg(output) == "TESTDEVICE01")
    }

    @Test("attestation serial parser reads system_profiler output")
    func attestationSerialParserReadsSystemProfiler() {
        let output = """
            Hardware:

                Hardware Overview:

                  Model Name: Mac Studio
                  Chip: Apple M3 Ultra
                  Serial Number (system): TESTDEVICE01
        """
        #expect(parseSerialNumberFromSystemProfiler(output) == "TESTDEVICE01")
    }

    @Test("EnrollmentError descriptions are stable")
    func enrollmentErrorDescriptions() {
        let cases: [(EnrollmentError, String)] = [
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
        // Every cleanup domain must be explicitly disabled. In particular,
        // secureEnclaveKey defaults to true and must never delete a developer's
        // live keychain identity during a test advertised as a no-op.
        LocalDataCleanup.purge(
            configDirectory: false,
            legacyKeyFiles: false,
            authToken: false,
            secureEnclaveKey: false
        )
        // No-op should always succeed.
    }
}

private enum ProofFailure: Error {
    case signing
}

private struct ProofSigner: AttestationSigner {
    let key: P256.Signing.PrivateKey
    var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func sign(_ data: Data) throws -> Data {
        return try key.signature(for: data).derRepresentation
    }
}

private struct FailingSigner: AttestationSigner {
    let publicKeyBase64 = "existing-key"
    func sign(_ data: Data) throws -> Data { throw ProofFailure.signing }
}
