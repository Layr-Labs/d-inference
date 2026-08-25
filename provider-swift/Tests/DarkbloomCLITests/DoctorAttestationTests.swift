import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Doctor attestation status")
struct DoctorAttestationTests {
    @Test("fresh running daemon selects its injected ephemeral signer identity")
    func selectsRunningDaemonEphemeralIdentity() throws {
        let process = ProcessIdentity(pid: 42, startTimeMicros: 123_456)
        let state = DaemonState(
            pid: 42,
            processIdentity: process,
            version: "test",
            writtenAt: 100,
            startedAt: 50,
            attestationPublicKey: "ephemeral-active-key")
        let resolution = resolveDoctorAttestationIdentity(
            daemonState: state,
            now: 120,
            readProcessIdentity: { $0 == 42 ? process : nil })
        guard case .available(let publicKey) = resolution else {
            Issue.record("fresh running daemon identity was not selected")
            return
        }
        #expect(publicKey == "ephemeral-active-key")

        let data = Data(
            #"""
            {
              "providers": [
                {
                  "provider_id": "unrelated-persistent-session",
                  "chip_name": "Apple Silicon",
                  "hardware_model": "Mac",
                  "se_public_key": "persistent-key",
                  "trust_level": "hardware",
                  "status": "online",
                  "mdm_verified": true,
                  "mda_verified": true,
                  "secure_enclave": true,
                  "sip_enabled": true,
                  "secure_boot_enabled": true
                },
                {
                  "provider_id": "ephemeral-session",
                  "chip_name": "Apple Silicon",
                  "hardware_model": "Mac",
                  "se_public_key": "ephemeral-active-key",
                  "trust_level": "self_signed",
                  "status": "online",
                  "mdm_verified": false,
                  "mda_verified": false,
                  "secure_enclave": true,
                  "sip_enabled": true,
                  "secure_boot_enabled": true
                }
              ]
            }
            """#.utf8
        )
        let match = try selectProviderAttestation(
            from: data,
            matchingSEPublicKey: publicKey)
        let provider = try #require(match)
        #expect(provider.providerID == "ephemeral-session")
    }

    @Test("missing, mismatched, stale, and legacy daemon identity never guesses a key")
    func unavailableDaemonIdentitiesWarn() {
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: nil, now: 120, readProcessIdentity: { _ in nil })
                == .unavailable(.daemonStateMissing))

        let process = ProcessIdentity(pid: 42, startTimeMicros: 123_456)
        let current = DaemonState(
            pid: 42,
            processIdentity: process,
            version: "test",
            writtenAt: 100,
            startedAt: 50,
            attestationPublicKey: "active-key")
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: current,
                now: 120,
                readProcessIdentity: { _ in ProcessIdentity(pid: 42, startTimeMicros: 999) })
                == .unavailable(.daemonProcessMismatch))
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: current, now: 200, readProcessIdentity: { _ in process })
                == .unavailable(.daemonStateStale(ageSeconds: 100)))

        let legacy = DaemonState(
            pid: 42,
            version: "old",
            writtenAt: 100,
            startedAt: 50)
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: legacy, now: 120, readProcessIdentity: { _ in process })
                == .unavailable(.daemonProcessIdentityNotReported))

        let legacySigner = DaemonState(
            pid: 42,
            version: "old",
            writtenAt: 100,
            startedAt: 50,
            attestationPublicKey: "unattributed-key")
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: legacySigner, now: 120, readProcessIdentity: { _ in process })
                == .unavailable(.daemonProcessIdentityNotReported))

        let noSigner = DaemonState(
            pid: 42,
            processIdentity: process,
            version: "test",
            writtenAt: 100,
            startedAt: 50)
        #expect(
            resolveDoctorAttestationIdentity(
                daemonState: noSigner, now: 120, readProcessIdentity: { _ in process })
                == .unavailable(.signerIdentityNotReported))
    }

    @Test("Secure Enclave diagnosis uses resolved identity without creating a key")
    func secureEnclaveDiagnosisUsesDaemonState() {
        let active = SEKeySelfTest.run(
            identity: .available(publicKey: "active-key"),
            secureEnclaveAvailable: true)
        #expect(active.level == .pass)

        let stopped = SEKeySelfTest.run(
            identity: .unavailable(.daemonProcessMismatch),
            secureEnclaveAvailable: true)
        #expect(stopped.level == .warn)

        let unavailable = SEKeySelfTest.run(
            identity: .unavailable(.signerIdentityNotReported),
            secureEnclaveAvailable: true)
        #expect(unavailable.level == .warn)
    }

    @Test("matches the redacted feed by Secure Enclave key")
    func matchesBySecureEnclaveKey() throws {
        let data = Data(
            #"""
            {
              "providers": [
                {
                  "provider_id": "stale-session",
                  "chip_name": "Apple M4 Max",
                  "hardware_model": "Mac16,1",
                  "se_public_key": "target-key",
                  "trust_level": "self_signed",
                  "status": "offline",
                  "mdm_verified": false,
                  "mda_verified": false,
                  "secure_enclave": true,
                  "sip_enabled": true,
                  "secure_boot_enabled": true
                },
                {
                  "provider_id": "live-session",
                  "chip_name": "Apple M4 Max",
                  "hardware_model": "Mac16,1",
                  "se_public_key": "target-key",
                  "trust_level": "hardware",
                  "status": "online",
                  "mdm_verified": true,
                  "mda_verified": true,
                  "secure_enclave": true,
                  "sip_enabled": true,
                  "secure_boot_enabled": true
                }
              ]
            }
            """#.utf8
        )

        let match = try selectProviderAttestation(
            from: data,
            matchingSEPublicKey: "target-key")
        let provider = try #require(match)
        #expect(provider.providerID == "live-session")
        #expect(provider.trustLevel == "hardware")
    }
}
