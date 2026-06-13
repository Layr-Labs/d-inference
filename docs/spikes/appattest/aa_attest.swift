// App Attest end-to-end attempt (issue #328). MUST run from a signed bundle
// carrying the App Attest entitlement; a raw swiftc binary will fail attestKey.
// Answers: (1) does a Developer-ID (non-App-Store) app get a valid attestation?
// (2) does attestKey succeed (implying genuine HW + SIP-on/Full-Security)?
// (3) what's the keyID + attestation CBOR (hand to a server verifier for the
//     Apple App Attest root + App-ID/rpId check).
import Foundation
import DeviceCheck
import CryptoKit

let svc = DCAppAttestService.shared
guard svc.isSupported else { print("isSupported=false; abort"); exit(1) }

// A server-issued one-time challenge would go here; fixed for the spike.
let challenge = Data("darkbloom-appattest-spike-\(Date().timeIntervalSince1970)".utf8)
let clientDataHash = Data(SHA256.hash(data: challenge))

let sem = DispatchSemaphore(value: 0)
svc.generateKey { keyID, err in
    if let err = err { print("generateKey ERROR: \(err)"); sem.signal(); return }
    guard let keyID = keyID else { print("generateKey: nil keyID"); sem.signal(); return }
    print("keyID = \(keyID)")
    svc.attestKey(keyID, clientDataHash: clientDataHash) { attestation, aerr in
        if let aerr = aerr {
            print("attestKey ERROR: \(aerr)")  // <-- the make-or-break result
        } else if let attestation = attestation {
            print("attestKey OK; attestation bytes = \(attestation.count)")
            print("ATTESTATION_B64=\(attestation.base64EncodedString())")
            print("CHALLENGE_B64=\(challenge.base64EncodedString())")
        }
        sem.signal()
    }
}
sem.wait()
