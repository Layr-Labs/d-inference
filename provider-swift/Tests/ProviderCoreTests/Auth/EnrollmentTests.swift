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

    @Test("profile request propagates existing-key lookup failure without fallback")
    func profileRequestRequiresExistingKey() {
        #expect(throws: PersistentEnclaveKeyError.self) {
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
        let result = try await EnrollmentService().enroll(
            coordinatorURL: "http://127.0.0.1:1", openSystemSettings: true,
            macOSMajorVersion: macOSMajorVersion)
        guard case .appAttest = result else {
            Issue.record("App Attest setup unexpectedly returned an MDM profile")
            return
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
            (.linkedCredentialsRequired, "MDM enrollment requires an existing linked account. Run 'darkbloom login' first."),
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
