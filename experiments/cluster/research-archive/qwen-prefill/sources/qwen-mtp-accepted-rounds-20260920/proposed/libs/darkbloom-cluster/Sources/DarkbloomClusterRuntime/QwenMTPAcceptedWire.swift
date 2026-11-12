import Foundation

/// These are private transaction frames, distinct from ordinary committed
/// residual ACKs. Canonical byte equality rejects surplus/duplicate fields.
enum QwenMTPAcceptedWire {
    static let maximumBytes = 4096
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try canonicalJSONData(value)
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("MTP frame exceeds byte limit") }
        return data
    }
    static func decode<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("MTP frame exceeds byte limit") }
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else { throw ProbeError("MTP frame is not exact canonical encoding") }
        return value
    }

    struct Proposal: Codable {
        let schema: String
        let ordinal: Int
        let requestID: UUID
        let roundID: UUID
        let agreementFingerprint: String
        let committedTargetInputs: Int
        let seedTokenID: Int
        let previousTokenChainSHA256: String
        let proposedTokenID: Int
        init(_ value: QwenResidentMTPProposal, ordinal: Int) {
            schema = "qwen_mtp_depth1_proposal_v1"; self.ordinal = ordinal
            requestID = value.requestID; roundID = value.roundID
            agreementFingerprint = value.agreementFingerprint; committedTargetInputs = value.committedTargetInputs
            seedTokenID = value.seedTokenID; previousTokenChainSHA256 = value.previousTokenChainSHA256
            proposedTokenID = value.proposedTokenID
        }
        func proposal(expectedOrdinal: Int) throws -> QwenResidentMTPProposal {
            guard schema == "qwen_mtp_depth1_proposal_v1", ordinal == expectedOrdinal else {
                throw ProbeError("MTP proposal version or round ordinal differs")
            }
            return .init(requestID: requestID, roundID: roundID, agreementFingerprint: agreementFingerprint,
                committedTargetInputs: committedTargetInputs, seedTokenID: seedTokenID,
                previousTokenChainSHA256: previousTokenChainSHA256, proposedTokenID: proposedTokenID)
        }
    }

    struct Boundary: Codable, Equatable {
        let schema: String
        let verificationFingerprint: String
        let producerStageFingerprint: String
        let step: Int
        let tokenID: Int
        let payloadSHA256: String
        init(request: QwenTargetVerificationRequest, step: Int, payloadSHA256: String) throws {
            guard payloadSHA256.count == 64, payloadSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw ProbeError("MTP residual digest is invalid")
            }
            schema = "qwen_mtp_provisional_boundary_v1"; verificationFingerprint = request.fingerprint
            producerStageFingerprint = request.agreement.descriptor.stageFingerprints[0]
            self.step = step; tokenID = try request.token(step: step); self.payloadSHA256 = payloadSHA256
        }
        func validate(request: QwenTargetVerificationRequest, step: Int) throws {
            guard self == (try .init(request: request, step: step, payloadSHA256: payloadSHA256)) else {
                throw ProbeError("MTP provisional boundary differs from this round")
            }
        }
    }

    struct Receipt: Codable {
        let schema: String
        let verificationFingerprint: String
        let rank: Int
        let base: Int
        let stagedInputs: Int
        let retainedInputs: Int
        let committedInputs: Int
        let pendingInputs: Int
        let newlyCommittedInputs: Int
        let isFinal: Bool
        init(_ value: QwenTargetVerificationLocalReceipt) {
            schema = "qwen_mtp_prefix_receipt_v1"; verificationFingerprint = value.verificationFingerprint
            rank = value.rank; base = value.base; stagedInputs = value.stagedInputs
            retainedInputs = value.retainedInputs; committedInputs = value.committedInputs
            pendingInputs = value.pendingInputs; newlyCommittedInputs = value.newlyCommittedInputs
            isFinal = value.isFinal
        }
        func receipt(peer: Int) throws -> QwenTargetVerificationLocalReceipt {
            guard schema == "qwen_mtp_prefix_receipt_v1", rank == peer else {
                throw ProbeError("MTP receipt version or peer differs")
            }
            return .init(verificationFingerprint: verificationFingerprint, rank: rank, base: base,
                stagedInputs: stagedInputs, retainedInputs: retainedInputs, committedInputs: committedInputs,
                pendingInputs: pendingInputs, newlyCommittedInputs: newlyCommittedInputs, isFinal: isFinal)
        }
    }
}
