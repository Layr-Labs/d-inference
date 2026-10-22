import Foundation
import MLX

/// Uses the resident's existing group and completed IO. There is no independent
/// owner, socket, sequence reset or fallback. This private plaintext laboratory
/// route is NOT admitted by the protected-record P32/O2 capability.
final class QwenMTPAcceptedTransport {
    private let collective: Collective
    private var busy = false
    private(set) var failed = false
    var rank: Int { collective.rank }

    init(collective: Collective) throws {
        guard collective.size == 2, (0...1).contains(collective.rank) else {
            throw ProbeError("MTP transport requires the original two-rank group")
        }
        self.collective = collective
    }
    func retire() { failed = true }

    func proposal(_ local: QwenResidentMTPProposal?, ordinal: Int,
        admit: (QwenResidentMTPProposal) throws -> QwenTargetVerificationRequest,
        check: () throws -> Void) throws -> QwenTargetVerificationRequest {
        try operation {
            if rank == 1 {
                guard let local else { throw ProbeError("MTP final rank has no actual assistant proposal") }
                let request = try admit(local)
                try send(QwenMTPAcceptedWire.encode(QwenMTPAcceptedWire.Proposal(local, ordinal: ordinal)), check: check)
                try receiveACK("proposal", request.fingerprint, check: check)
                return request
            }
            guard local == nil else { throw ProbeError("MTP ingress rank cannot invent an assistant proposal") }
            let value = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Proposal.self, receive(check: check))
            let request = try admit(value.proposal(expectedOrdinal: ordinal))
            try sendACK("proposal", request.fingerprint, check: check)
            return request
        }
    }

    func sendBoundary(_ boundary: QwenTargetVerificationBoundary, request: QwenTargetVerificationRequest,
                      step: Int, check: () throws -> Void) throws -> QwenMTPAcceptedWire.Boundary {
        try operation {
            guard rank == 0 else { throw ProbeError("Only MTP ingress sends provisional residuals") }
            let owned = try boundary.ownedCopy(check: check)
            try owned.validate(request: request, step: step, dtype: .bfloat16)
            let packet = try QwenMTPAcceptedWire.Boundary(request: request, step: step, payloadSHA256: owned.payloadSHA256)
            let bytes = try QwenMTPAcceptedWire.encode(packet), fingerprint = sha256(bytes)
            try send(bytes, check: check)
            try receiveACK("provisional-ready", fingerprint, check: check)
            _ = try collective.sendCompleted(owned.array, to: 1,
                maximumBytes: request.agreement.request.profile.hiddenSize * 2, check: check)
            try receiveACK("provisional-staged", fingerprint, check: check)
            return packet
        }
    }

    func receiveBoundary<T>(request: QwenTargetVerificationRequest, step: Int,
        consume: (QwenTargetVerificationBoundary) throws -> T,
        check: () throws -> Void) throws -> (T, QwenMTPAcceptedWire.Boundary) {
        try operation {
            guard rank == 1 else { throw ProbeError("Only MTP final rank consumes provisional residuals") }
            let bytes = try receive(check: check)
            let packet = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Boundary.self, bytes)
            try packet.validate(request: request, step: step)
            let fingerprint = sha256(bytes), hidden = request.agreement.request.profile.hiddenSize
            try sendACK("provisional-ready", fingerprint, check: check)
            let array = try collective.receiveCompleted(shape: [1, 1, hidden], dtype: .bfloat16,
                from: 0, maximumBytes: hidden * 2, check: check)
            let boundary = QwenTargetVerificationBoundary(verificationFingerprint: request.fingerprint,
                producerStageFingerprint: packet.producerStageFingerprint, step: step,
                tokenID: packet.tokenID, payloadSHA256: packet.payloadSHA256, array: array)
            try boundary.validate(request: request, step: step, dtype: .bfloat16)
            let value = try consume(boundary)
            try check()
            // This acknowledges provisional native staging only. The separate
            // receipt exchange below must precede generation/publication.
            try sendACK("provisional-staged", fingerprint, check: check)
            return (value, packet)
        }
    }

    func receipts(_ local: QwenTargetVerificationLocalReceipt, check: () throws -> Void)
        throws -> [QwenTargetVerificationLocalReceipt] {
        try operation {
            guard local.rank == rank else { throw ProbeError("MTP local receipt rank differs") }
            let data = try QwenMTPAcceptedWire.encode(QwenMTPAcceptedWire.Receipt(local))
            let peerData: Data
            // Both contributions complete before either side rejects contents.
            if rank == 0 { try send(data, check: check); peerData = try receive(check: check) }
            else { peerData = try receive(check: check); try send(data, check: check) }
            let peer = try QwenMTPAcceptedWire.decode(QwenMTPAcceptedWire.Receipt.self, peerData).receipt(peer: 1-rank)
            return rank == 0 ? [local, peer] : [peer, local]
        }
    }

    private func send(_ data: Data, check: () throws -> Void) throws {
        guard (1...QwenMTPAcceptedWire.maximumBytes).contains(data.count) else { throw ProbeError("MTP send byte limit") }
        _ = try collective.sendCompleted(MLXArray([UInt32(data.count)]), to: 1-rank, maximumBytes: 4, check: check)
        _ = try collective.sendCompleted(MLXArray(Array(data)), to: 1-rank,
            maximumBytes: QwenMTPAcceptedWire.maximumBytes, check: check)
    }
    private func receive(check: () throws -> Void) throws -> Data {
        let count = try collective.receiveCompleted(shape: [1], dtype: .uint32, from: 1-rank,
            maximumBytes: 4, check: check).item(UInt32.self)
        guard count > 0, Int(count) <= QwenMTPAcceptedWire.maximumBytes else { throw ProbeError("MTP receive byte limit") }
        let value = try collective.receiveCompleted(shape: [Int(count)], dtype: .uint8, from: 1-rank,
            maximumBytes: QwenMTPAcceptedWire.maximumBytes, check: check).asData().data
        try check(); return value
    }
    private func ack(_ phase: String, _ fingerprint: String) throws -> [UInt8] {
        Array(sha256(try canonicalJSONData(["qwen-mtp-depth1-ack-v1", phase, fingerprint])).utf8)
    }
    private func sendACK(_ phase: String, _ fingerprint: String, check: () throws -> Void) throws {
        _ = try collective.sendCompleted(MLXArray(try ack(phase, fingerprint)), to: 1-rank, maximumBytes: 64, check: check)
    }
    private func receiveACK(_ phase: String, _ fingerprint: String, check: () throws -> Void) throws {
        let actual = try collective.receiveCompleted(shape: [64], dtype: .uint8, from: 1-rank,
            maximumBytes: 64, check: check).asArray(UInt8.self)
        guard actual == (try ack(phase, fingerprint)) else { throw ProbeError("MTP phase acknowledgement differs") }
        try check()
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !busy, !failed else { failed = true; throw ProbeError("MTP transport is failed or reentered") }
        busy = true; defer { busy = false }
        do { let value = try body(); guard !failed else { throw ProbeError("MTP transport poisoned") }; return value }
        catch { failed = true; throw error }
    }
}
