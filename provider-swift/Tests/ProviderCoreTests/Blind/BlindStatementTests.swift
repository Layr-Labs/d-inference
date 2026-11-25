import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// The bytes a blind statement's signature covers, against the shared
/// statement vectors, and the JSON form sent beside the signature.
@Suite("Blind statements")
struct BlindStatementTests {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static var usageStatement: BlindStatement {
        BlindStatement.usage(
            BlindStatement.UsageTerms(
                requestID: "req-0001",
                signedRequestSHA256: Data(base64Encoded: "Jrc92/sjZyqPrLj/EUcBQo4WdFA322KHiKiZE05IpZw=")!,
                recipientPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
                clientPublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
                clientNonce: "AAECAwQFBgcICQoLDA0ODw",
                model: "qwen3.5-9b-mlx-4bit",
                maxTokens: 256),
            usage: UsageInfo(promptTokens: 42, completionTokens: 7, reasoningTokens: 0, cachedTokens: nil),
            finishReason: .stop, chunkCount: 3,
            framesSHA256: Data(base64Encoded: "WUz9JgfU8J4c5iQSA+QYys/tVFBjeSvF6revqtvwxOA=")!,
            sealedUsageSHA256: Data(base64Encoded: "Ck5MKUMuywG5X4fYf/r/nLTzbOS4n/GhoTatHHOSrgc=")!,
            issuedAtMs: 1_795_640_000_000)
    }

    @Test("a usage statement's signed bytes match the shared vector")
    func usageVector() {
        let bytes = Self.usageStatement.signedBytes
        #expect(Self.hex(bytes).hasPrefix("000000186461726b626c6f6f6d2d626c696e642d75736167652d7631"))
        #expect(Self.hex(Data(SHA256.hash(data: bytes)))
            == "25a3a61994141d646014b63c31804286041ee69f12606ec3bf524f4e3003bbdc")
    }

    @Test("a refusal statement's signed bytes match the shared vector")
    func refusalVector() {
        let statement = BlindStatement.refusal(
            requestID: "req-0002", signedRequestSHA256: nil, reason: .sealUnopenable, issuedAtMs: 1_795_640_000_001)
        #expect(Self.hex(statement.signedBytes) == "0000001a6461726b626c6f6f6d2d626c696e642d7265667573616c2d7631"
            + "000000087265712d30303032000000000000000f7365616c5f756e6f70656e61626c65"
            + "0000000d31373935363430303030303031")
        #expect(Self.hex(Data(SHA256.hash(data: statement.signedBytes)))
            == "78e7d4238f07172fe037f08b2d3cab270b9c076be74dc59089d62dda7a93d67c")
    }

    @Test("the JSON form names each field once, integers as numbers, and its signature verifies")
    func jsonForm() throws {
        let signer = ServeLoopTestSigner()
        let signed = try Self.usageStatement.signed(by: signer)
        let data = try JSONEncoder().encode(signed)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statement = try #require(object["statement"] as? [String: Any])
        #expect(Set(statement.keys) == Set(Self.usageStatement.fields.map(\.name)))
        #expect(statement["max_tokens"] as? Int == 256)
        #expect(statement["prompt_tokens"] as? Int == 42)
        #expect(statement["issued_at_ms"] as? Int64 == 1_795_640_000_000)
        #expect(statement["model"] as? String == "qwen3.5-9b-mlx-4bit")
        #expect(try JSONDecoder().decode(SignedBlindStatement.self, from: data) == signed)

        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: #require(Data(base64Encoded: signed.signature)))
        let publicKey = try P256.Signing.PublicKey(
            rawRepresentation: #require(Data(base64Encoded: signer.publicKeyBase64)))
        #expect(publicKey.isValidSignature(signature, for: Self.usageStatement.signedBytes))
    }

    @Test("a refusal is signed by the Mac, and names the request's signature digest once it verified")
    func refusalFailure() throws {
        let signer = ServeLoopTestSigner()
        let digest = Data(SHA256.hash(data: Data("header.payload.signature".utf8)))
        let failure = ProviderLoop.blindRefusalFailure(
            BlindRefusal(.boundExceeded, signedRequestSHA256: digest), requestId: "req-3", signer: signer)
        #expect(failure.code == .blindRefused)
        #expect(failure.statusCode == 400)
        let refusal = try #require(failure.blindRefusal)
        #expect(refusal.statement["reason"] == .text("bound_exceeded"))
        #expect(refusal.statement["signed_request_sha256"] == .text(digest.base64EncodedString()))
        #expect(try BlindRequestFixture.refusalVerifies(refusal, publicKeyBase64: signer.publicKeyBase64))

        let unsigned = ProviderLoop.blindRefusalFailure(BlindRefusal(.posture), requestId: "req-4", signer: nil)
        #expect(unsigned.statusCode == 502)
        #expect(unsigned.blindRefusal == nil)
    }
}
