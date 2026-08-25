import Foundation
import Testing

@testable import darkbloom

@Suite("Doctor attestation status")
struct DoctorAttestationTests {
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

        let provider = try #require(
            selectProviderAttestation(from: data, matchingSEPublicKey: "target-key")
        )
        #expect(provider.providerID == "live-session")
        #expect(provider.trustLevel == "hardware")
    }
}
