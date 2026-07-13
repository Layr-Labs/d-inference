import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

private func canonicalIdentity() throws -> TerminalAttemptIdentity {
    try TerminalAttemptIdentity(
        providerID: "11111111-1111-1111-1111-111111111111",
        providerProcessGeneration: "22222222-2222-2222-2222-222222222222",
        sessionEpoch: 7,
        requestID: "33333333-3333-3333-3333-333333333333",
        attemptID: "44444444-4444-4444-4444-444444444444",
        reservationID: "55555555-5555-5555-5555-555555555555",
        leaseID: "66666666-6666-6666-6666-666666666666"
    )
}

@Test
func canonicalTerminalExactlyMatchesRustGoldenVector() throws {
    let terminal = try CanonicalProviderTerminal(
        identity: canonicalIdentity(),
        outcome: .completed,
        promptTokens: 10,
        completionTokens: 5,
        responseHash: try TerminalDigest(bytes: Data(repeating: 0x77, count: 32)),
        finalGeneratedTokens: 5,
        rollingDigest: try TerminalDigest(bytes: Data(repeating: 0x88, count: 32)),
        model: "model-a"
    )

    let expected = Data(
        #"{"attempt_id":"44444444-4444-4444-4444-444444444444","completion_tokens":5,"final_generated_tokens":5,"lease_id":"66666666-6666-6666-6666-666666666666","model":"model-a","outcome":"completed","prompt_tokens":10,"provider_id":"11111111-1111-1111-1111-111111111111","provider_process_generation":"22222222-2222-2222-2222-222222222222","request_id":"33333333-3333-3333-3333-333333333333","reservation_id":"55555555-5555-5555-5555-555555555555","response_hash":"d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3c=","rolling_digest":"iIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIg=","session_epoch":7}"#
            .utf8)
    #expect(terminal.canonicalBytes() == expected)
    #expect(terminal.terminalDigest == .sha256(expected))
}

@Test
func canonicalTerminalPinsOptionalFieldOrderAndSerdeEscaping() throws {
    let terminal = try CanonicalProviderTerminal(
        identity: canonicalIdentity(),
        outcome: .error,
        errorClass: .modelNotReady,
        promptTokens: 1,
        completionTokens: 2,
        reasoningTokens: 2,
        responseHash: .sha256(Data("response".utf8)),
        finalGeneratedTokens: 4,
        rollingDigest: .sha256(Data("rolling".utf8)),
        model: "org/模型-\"quoted\""
    )
    let text = try #require(String(data: terminal.canonicalBytes(), encoding: .utf8))

    #expect(text.contains(#""error_class":"model_not_ready","final_generated_tokens""#))
    #expect(
        text.contains(
            #""provider_process_generation":"22222222-2222-2222-2222-222222222222","reasoning_tokens":2,"request_id""#
        ))
    #expect(text.contains(#""model":"org/模型-\"quoted\"""#))
}

@Test
func terminalSemanticRelationshipsFailClosed() throws {
    let digest = TerminalDigest.sha256(Data())
    #expect(throws: TerminalCanonicalError.reasoningTokensExceedCompletion) {
        _ = try CanonicalProviderTerminal(
            identity: canonicalIdentity(),
            outcome: .cancelled,
            promptTokens: 1,
            completionTokens: 1,
            reasoningTokens: 2,
            responseHash: digest,
            finalGeneratedTokens: 2,
            rollingDigest: digest,
            model: "model-a"
        )
    }
    #expect(throws: TerminalCanonicalError.completedTokenMismatch) {
        _ = try CanonicalProviderTerminal(
            identity: canonicalIdentity(),
            outcome: .completed,
            promptTokens: 1,
            completionTokens: 1,
            responseHash: digest,
            finalGeneratedTokens: 2,
            rollingDigest: digest,
            model: "model-a"
        )
    }
    #expect(throws: TerminalCanonicalError.errorTerminalMissingErrorClass) {
        _ = try CanonicalProviderTerminal(
            identity: canonicalIdentity(),
            outcome: .error,
            promptTokens: 1,
            completionTokens: 0,
            responseHash: digest,
            finalGeneratedTokens: 0,
            rollingDigest: digest,
            model: "model-a"
        )
    }
}

@Test
func terminalIdentityCanonicalizesUppercaseAndRustCompactUUIDText() throws {
    let identity = try TerminalAttemptIdentity(
        providerID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        providerProcessGeneration: "22222222-2222-2222-2222-222222222222",
        sessionEpoch: 0,
        requestID: "33333333-3333-3333-3333-333333333333",
        attemptID: "44444444-4444-4444-4444-444444444444",
        reservationID: "55555555-5555-5555-5555-555555555555",
        leaseID: "66666666-6666-6666-6666-666666666666"
    )
    #expect(identity.providerID == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

    let compact = try TerminalAttemptIdentity(
        providerID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        providerProcessGeneration: identity.providerProcessGeneration,
        sessionEpoch: 0,
        requestID: identity.requestID,
        attemptID: identity.attemptID,
        reservationID: identity.reservationID,
        leaseID: identity.leaseID
    )
    #expect(compact.providerID == identity.providerID)

    #expect(throws: TerminalCanonicalError.self) {
        _ = try TerminalAttemptIdentity(
            providerID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaz",
            providerProcessGeneration: identity.providerProcessGeneration,
            sessionEpoch: 0,
            requestID: identity.requestID,
            attemptID: identity.attemptID,
            reservationID: identity.reservationID,
            leaseID: identity.leaseID
        )
    }
}

@Test
func rollingResponseHashPinsChainAndMonotonicCounters() throws {
    var rolling = RollingResponseSHA256()
    let firstBytes = Data("alpha".utf8)
    let first = try rolling.append(
        sequence: 4,
        cumulativeTokens: 2,
        responseBytes: firstBytes
    )

    var firstChain = Data(repeating: 0, count: 32)
    appendUInt64BE(4, to: &firstChain)
    appendUInt64BE(2, to: &firstChain)
    appendUInt64BE(UInt64(firstBytes.count), to: &firstChain)
    firstChain.append(firstBytes)
    #expect(first.rollingDigest == .sha256(firstChain))
    #expect(first.responseHash == .sha256(firstBytes))

    let secondBytes = Data("βeta".utf8)
    let second = try rolling.append(
        sequence: 9,
        cumulativeTokens: 5,
        responseBytes: secondBytes
    )
    var response = firstBytes
    response.append(secondBytes)
    #expect(second.responseHash == .sha256(response))
    #expect(second.sequence == 9)
    #expect(second.cumulativeTokens == 5)

    let beforeInvalid = rolling.checkpoint
    #expect(throws: TerminalCanonicalError.self) {
        _ = try rolling.append(sequence: 9, cumulativeTokens: 6, responseBytes: Data([1]))
    }
    #expect(throws: TerminalCanonicalError.self) {
        _ = try rolling.append(sequence: 10, cumulativeTokens: 5, responseBytes: Data([1]))
    }
    #expect(rolling.checkpoint == beforeInvalid, "rejected updates must not mutate either hash")
}

@Test
func frozenTerminalWireShapeUsesRustFieldNames() throws {
    let terminal = try CanonicalProviderTerminal(
        identity: canonicalIdentity(),
        outcome: .cancelled,
        errorClass: .cancelled,
        promptTokens: 9,
        completionTokens: 1,
        responseHash: .sha256(Data()),
        finalGeneratedTokens: 1,
        rollingDigest: .zero,
        model: "model-a"
    )
    let frozen = FrozenProviderTerminal(
        terminal: terminal,
        terminalDigest: terminal.terminalDigest,
        seSignature: Data([0x30, 0x01])
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: frozen.wireJSONData()) as? [String: Any])
    #expect(object["terminal_digest"] as? String == terminal.terminalDigest.base64)
    #expect(object["se_signature"] as? String == "MAE=")
    #expect(object["error_class"] as? String == "cancelled")
    #expect(object["reasoning_tokens"] == nil)

    let protocolTerminal = frozen.protocolV2
    #expect(try protocolTerminal.canonicalBytes() == terminal.canonicalBytes())
    #expect(protocolTerminal.terminalDigest.bytes == terminal.terminalDigest.bytes)
    #expect(protocolTerminal.signature.bytes == frozen.seSignature)
}

private func appendUInt64BE(_ value: UInt64, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}
