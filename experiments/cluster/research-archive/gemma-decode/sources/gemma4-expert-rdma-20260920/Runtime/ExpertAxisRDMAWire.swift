import Foundation
import MLX

/// One serialized existing Collective. Every allocation has a locally known
/// bound; payloads are checksummed but are not authenticated/encrypted records.
final class ExpertAxisRDMAWire {
    let job: ExpertAxisRDMAJob, group: Collective
    private var sent = 0, received = 0, failed = false
    private(set) var sentControlBytes = 0, receivedControlBytes = 0
    private(set) var sentTensorBytes = 0, receivedTensorBytes = 0
    init(job: ExpertAxisRDMAJob, group: Collective) throws {
        guard group.transport == .jaccl, group.size == 2, group.rank == job.rank else {
            throw ProbeError("Expert RDMA rank/group differs from exact job")
        }
        self.job = job; self.group = group
    }
    func send(_ value: ExpertAxisRDMAControl, check: () throws -> Void) throws {
        do {
            guard !failed, sent < ExpertAxisRDMACodec.recordLimit else { throw ProbeError("Expert RDMA send is retired/exhausted") }
            try check()
            let bytes = try canonicalJSONData(ExpertAxisRDMAPacket(schema: "gemma4_expert_rdma_wire_v1",
                scopeSHA256: job.scopeSHA256, senderRank: job.rank, ordinal: sent, value: value))
            guard (1...ExpertAxisRDMACodec.controlLimit).contains(bytes.count) else { throw ProbeError("Expert RDMA control exceeds bound") }
            _ = try group.sendCompleted(MLXArray([UInt32(bytes.count)]), to: 1-job.rank, maximumBytes: 4, check: check)
            _ = try group.sendCompleted(MLXArray(bytes, [bytes.count], dtype: .uint8), to: 1-job.rank,
                maximumBytes: ExpertAxisRDMACodec.controlLimit, check: check)
            sent += 1; sentControlBytes += bytes.count+4; try check()
        } catch { failed = true; throw error }
    }
    func receive(check: () throws -> Void) throws -> ExpertAxisRDMAControl {
        do {
            guard !failed, received < ExpertAxisRDMACodec.recordLimit else { throw ProbeError("Expert RDMA receive is retired/exhausted") }
            try check()
            let prefix = try group.receiveCompleted(shape: [1], dtype: .uint32, from: 1-job.rank, maximumBytes: 4, check: check)
            let length = Int(prefix.item(UInt32.self)); try check()
            guard (1...ExpertAxisRDMACodec.controlLimit).contains(length) else { throw ProbeError("Expert RDMA control prefix exceeds bound") }
            let buffer = try group.receiveCompleted(shape: [length], dtype: .uint8, from: 1-job.rank,
                maximumBytes: ExpertAxisRDMACodec.controlLimit, check: check)
            let bytes = buffer.asData(access: .copy).data; try check()
            let value = try ExpertAxisRDMACodec.decode(bytes, scope: job.scopeSHA256, sender: 1-job.rank, ordinal: received)
            received += 1; receivedControlBytes += length+4; return value
        } catch { failed = true; throw error }
    }
    func require(_ expected: ExpertAxisRDMAControl, check: () throws -> Void) throws {
        guard try receive(check: check) == expected else { failed = true; throw ProbeError("Expert RDMA peer control differs from local expectation") }
    }
    func checkpoint(_ name: String, check: () throws -> Void) throws {
        guard ["begin", "banks-loaded", "banks-released"].contains(name) else { throw ProbeError("Unknown expert checkpoint") }
        let value = ExpertAxisRDMAControl(event: name)
        if job.rank == 0 { try send(value, check: check); try require(value, check: check) }
        else { try require(value, check: check); try send(value, check: check) }
    }
    func sendTensor(_ array: MLXArray?, event: String, rows: Int, index: Int, route: String,
                    check: () throws -> Void) throws -> String {
        try validateTensorContext(event: event, sender: job.rank, rows: rows, index: index, route: route)
        return try autoreleasepool {
            let bytes = rows * 2816 * 2
            var owned: MLXArray?
            let hash: String
            if rows == 0 {
                guard case .none = array else { throw ProbeError("Empty expert rank returned a tensor") }
                hash = sha256(Data())
            } else {
                guard let array, array.shape == [rows,2816], array.dtype == .bfloat16 else { throw ProbeError("Expert returned tensor geometry differs") }
                owned = try copySelectedTensor(array, selection: .all)
                eval(owned!); try check()
                let data = owned!.asData(access: .copy).data; try check()
                guard data.count == bytes else { throw ProbeError("Expert tensor copy byte count differs") }
                hash = sha256(data)
            }
            var header = ExpertAxisRDMAControl(event: event, caseIndex: index, rows: rows)
            header.payloadBytes = bytes; header.payloadSHA256 = hash; header.routeSHA256 = route
            try send(header, check: check)
            try require(header.changingEvent(event+"-ready"), check: check)
            if let owned {
                _ = try group.sendCompleted(owned, to: 1-job.rank, maximumBytes: ExpertAxisRDMACodec.payloadLimit, check: check)
                sentTensorBytes += bytes
            }
            try require(header.changingEvent(event+"-consumed"), check: check)
            return hash
        }
    }
    func receiveTensor(event: String, rows: Int, index: Int, route: String, expectedSHA256: String? = nil,
                       check: () throws -> Void) throws -> (MLXArray?, String) {
        try validateTensorContext(event: event, sender: 1-job.rank, rows: rows, index: index, route: route)
        let actual = try receive(check: check)
        var expected = ExpertAxisRDMAControl(event: event, caseIndex: index, rows: rows)
        expected.payloadBytes = rows*2816*2; expected.payloadSHA256 = actual.payloadSHA256; expected.routeSHA256 = route
        guard actual == expected, qwenStageWireIsSHA256(actual.payloadSHA256),
              expectedSHA256 == nil || expectedSHA256 == actual.payloadSHA256,
              rows != 0 || actual.payloadSHA256 == sha256(Data()) else {
            failed = true; throw ProbeError("Expert tensor header differs from admitted allocation/route")
        }
        try send(expected.changingEvent(event+"-ready"), check: check)
        let value: MLXArray?
        if rows == 0 { value = nil }
        else {
            value = try group.receiveCompleted(shape: [rows,2816], dtype: .bfloat16, from: 1-job.rank,
                maximumBytes: ExpertAxisRDMACodec.payloadLimit, check: check)
            let bytes = value!.asData(access: .copy).data; try check()
            guard bytes.count == expected.payloadBytes, sha256(bytes) == actual.payloadSHA256 else {
                failed = true; throw ProbeError("Expert tensor received bytes differ")
            }
            receivedTensorBytes += bytes.count
        }
        try send(expected.changingEvent(event+"-consumed"), check: check)
        return (value, actual.payloadSHA256)
    }
    private func validateTensorContext(event: String, sender: Int, rows: Int, index: Int, route: String) throws {
        guard !failed, job.tokenCounts.indices.contains(index), qwenStageWireIsSHA256(route),
              (event == "input" && sender == 0 && rows == job.tokenCounts[index])
                || (event == "unweighted-output" && sender == 1 && (0...(job.tokenCounts[index]*8)).contains(rows)),
              rows*2816*2 <= ExpertAxisRDMACodec.payloadLimit else {
            throw ProbeError("Expert RDMA tensor operation is outside its fixed bounds")
        }
    }
}
