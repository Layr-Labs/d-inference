import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// The shared request-signing vectors (the same file is in the platform
/// repository): every frame verifies or is refused exactly as the vector says.
@Suite("Coordinator request signature vectors")
struct CoordinatorRequestJWSVectorTests {
    struct Vectors {
        let root: [String: Any]
        let pins: [CoordinatorRequestSigningPin]
        let recipient: Data
        let now: Date

        init() throws {
            let url = try #require(Bundle.module.url(
                forResource: "request-signing-vectors", withExtension: "json", subdirectory: "Fixtures"))
            root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let keys = try #require(root["keys"] as? [String: [String: Any]])
            let verifier = try #require(root["verifier"] as? [String: Any])
            pins = try (try #require(verifier["pins"] as? [[String: Any]])).map { pin in
                let key = try #require(keys[try #require(pin["key"] as? String)])
                let built = try #require(CoordinatorRequestSigningPin(
                    base64PublicKey: try #require(key["public_key"] as? String),
                    expiresAtMs: try #require(pin["expires_at_ms"] as? NSNumber).int64Value))
                #expect(built.keyID == pin["kid"] as? String)
                return built
            }
            recipient = try #require(Data(base64Encoded: try #require(verifier["recipient_public_key"] as? String)))
            let verifyAt = try #require(verifier["verify_at_ms"] as? NSNumber).int64Value
            now = Date(timeIntervalSince1970: Double(verifyAt) / 1000)
        }

        var frames: [[String: Any]] { root["frames"] as? [[String: Any]] ?? [] }

        func verify(_ frame: [String: Any], signedRequest: String? = nil) throws
            -> Result<CoordinatorRequestJWS.Verified, CoordinatorRequestJWS.Refusal> {
            let body = try #require(frame["encrypted_body"] as? [String: Any])
            return CoordinatorRequestJWS.verify(
                signedRequest ?? frame["signed_request"] as? String, pins: pins,
                requestID: try #require(frame["request_id"] as? String),
                serviceReservationID: frame["service_reservation_id"] as? String,
                recipientPublicKey: recipient,
                senderPublicKey: try #require(Data(base64Encoded: try #require(body["ephemeral_public_key"] as? String))),
                ciphertext: try #require(Data(base64Encoded: try #require(body["ciphertext"] as? String))),
                now: now)
        }
    }

    @Test("every frame vector verifies or is refused for its stated reason")
    func frameVectors() throws {
        let vectors = try Vectors()
        #expect(vectors.frames.count == 38)
        for vector in vectors.frames {
            let name = try #require(vector["name"] as? String)
            let expect = try #require(vector["expect"] as? [String: Any])
            let frame = try #require(vector["frame"] as? [String: Any])
            switch try vectors.verify(frame) {
            case .success(let verified):
                #expect(expect["result"] as? String == "serve", "\(name) served")
                for field in expect["absent"] as? [String] ?? [] {
                    switch field {
                    case "prompt_work": #expect(verified.payload.promptWork == nil, "\(name)")
                    case "gemma_prompt_contract": #expect(verified.payload.gemmaPromptContract == nil, "\(name)")
                    case "cache_scope": #expect(verified.payload.cacheScope == nil, "\(name)")
                    default: Issue.record("\(name): unknown absent field \(field)")
                    }
                }
            case .failure(let refusal):
                #expect(expect["result"] as? String == "refuse", "\(name) refused as \(refusal.rawValue)")
                #expect(refusal.rawValue == expect["reason"] as? String, "\(name) refused as \(refusal.rawValue)")
            }
        }
    }

    @Test("every changed payload byte is refused as a bad signature")
    func payloadMutations() throws {
        let vectors = try Vectors()
        let mutation = try #require(vectors.root["payload_mutation"] as? [String: Any])
        let base = try #require(vectors.frames.first { $0["name"] as? String == mutation["base"] as? String })
        let frame = try #require(base["frame"] as? [String: Any])
        let parts = try #require(frame["signed_request"] as? String).split(separator: ".").map(String.init)
        let payload = try #require(CoordinatorRequestJWS.decodeBase64URL(parts[1][...]))
        for index in payload.indices {
            var changed = payload
            changed[index] ^= 1
            let jws = parts[0] + "." + CoordinatorRequestJWS.base64URL(changed) + "." + parts[2]
            #expect(try vectors.verify(frame, signedRequest: jws) == .failure(.badSignature), "byte \(index)")
        }
    }

    @Test("the key id is the RFC 7638 thumbprint, and the header names it exactly")
    func keyIDAndHeader() throws {
        let vectors = try Vectors()
        let a4 = try #require(vectors.root["rfc8037_a4"] as? [String: Any])
        #expect(vectors.pins[0].keyID == a4["jwk_thumbprint"] as? String)
        let keys = try #require(vectors.root["keys"] as? [String: [String: Any]])
        #expect(CoordinatorRequestJWS.protectedHeader(kid: vectors.pins[0].keyID)
            == keys["pinned"]?["protected_header"] as? String)
    }

    @Test("a signature scalar at or above the group order is not canonical")
    func scalarBelowTheGroupOrder() {
        let order: [UInt8] = [
            0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        ]
        var below = order
        below[0] -= 1
        var above = order
        above[31] += 1
        #expect(CoordinatorRequestJWS.isCanonicalScalar(Data(below)))
        #expect(!CoordinatorRequestJWS.isCanonicalScalar(Data(order)))
        #expect(!CoordinatorRequestJWS.isCanonicalScalar(Data(above)))
        #expect(CoordinatorRequestJWS.isCanonicalScalar(Data(count: 32)))
        #expect(!CoordinatorRequestJWS.isCanonicalScalar(Data(count: 31)))
    }
}
