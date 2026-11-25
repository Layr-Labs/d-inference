import Foundation
import MLX

extension Gemma4ExpertWire {
    func sendRows(_ array: MLXArray?, rows: Int, layerScope: String,
                  check: () throws -> Void) throws -> String {
        guard (0...input.assignmentLimit).contains(rows), qwenStageWireIsSHA256(layerScope) else {
            throw ProbeError("Gemma EP sender rows exceed admitted frame")
        }
        return try autoreleasepool {
            try check()
            let bytes = rows * 2816 * 2
            var owned: MLXArray?
            let hash: String
            if rows == 0 {
                guard case .none = array else { throw ProbeError("Empty Gemma EP rank supplied rows") }
                hash = sha256(Data())
            } else {
                guard let array, array.shape == [rows,2816], array.dtype == .bfloat16 else {
                    throw ProbeError("Gemma EP sender shape/type contains padding or differs")
                }
                // Existing native compact-storage proof, not a new copy API.
                owned = try copySelectedTensor(array, selection: .all); try check()
                let data = owned!.asData(access: .copy).data; try check()
                guard data.count == bytes else { throw ProbeError("Gemma EP sender bytes differ") }
                hash = sha256(data)
            }
            let header = Gemma4ExpertWireValue(event: "rows", layerScopeSHA256: layerScope,
                rows: rows, payloadBytes: bytes, payloadSHA256: hash)
            try send(header, check: check); try require(header.event("rows-ready"), check: check)
            try withExtendedLifetime(owned) {
                if let owned {
                    _ = try group.sendCompleted(owned, to: 1-rank,
                        maximumBytes: input.payloadByteLimit, check: check)
                }
                try require(header.event("rows-consumed"), check: check)
            }
            try noteSentTensor(bytes)
            return hash
        }
    }

    func receiveRows(rows: Int, layerScope: String, check: () throws -> Void) throws -> (MLXArray?, String) {
        guard (0...input.assignmentLimit).contains(rows), qwenStageWireIsSHA256(layerScope) else {
            throw ProbeError("Gemma EP receiver rows exceed admitted frame")
        }
        try check()
        let actual = try receive(check: check)
        let bytes = rows * 2816 * 2
        let expected = Gemma4ExpertWireValue(event: "rows", layerScopeSHA256: layerScope,
            rows: rows, payloadBytes: bytes, payloadSHA256: actual.payloadSHA256)
        let hash = try Gemma4ExpertWireCodec.requireRows(actual, rows:rows,
            limit:input.assignmentLimit,layerScope:layerScope)
        try send(expected.event("rows-ready"), check: check)
        let array: MLXArray?
        if rows == 0 { array = nil }
        else {
            array = try group.receiveCompleted(shape: [rows,2816], dtype: .bfloat16,
                from: 1-rank, maximumBytes: input.payloadByteLimit, check: check)
            let data = array!.asData(access: .copy).data; try check()
            guard data.count == bytes, sha256(data) == hash else { throw ProbeError("Gemma EP received checksum differs") }
        }
        try send(expected.event("rows-consumed"), check: check)
        try noteReceivedTensor(bytes)
        return (array,hash)
    }
}
