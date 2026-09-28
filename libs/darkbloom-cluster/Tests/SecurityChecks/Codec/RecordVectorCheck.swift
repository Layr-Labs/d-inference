import CryptoKit
import Foundation

private func vectorHex(_ object: [String: Any], _ field: String) throws -> Data {
    guard let text = object[field] as? String, text.count % 2 == 0 else {
        throw RecordFixtureError.failed("missing fixed vector hex field")
    }
    let bytes = Array(text.utf8)
    func nibble(_ byte: UInt8) throws -> UInt8 {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        default: throw RecordFixtureError.failed("noncanonical fixed vector hex")
        }
    }
    var result = Data()
    for index in stride(from: 0, to: bytes.count, by: 2) {
        result.append(try nibble(bytes[index]) * 16 + nibble(bytes[index + 1]))
    }
    return result
}

func checkIndependentVectors(_ url: URL) throws {
    let raw = try Data(contentsOf: url)
    guard raw.count < 16_384,
          let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          object["schema"] as? String == "darkbloom_rdma_record_fixed_vector_v1",
          object["fixtureOnly"] as? Bool == true,
          let epochString = object["epoch"] as? String, let epoch = UUID(uuidString: epochString),
          let maximum = object["maximumPlaintextBytes"] as? Int,
          let records = object["maximumRecordsPerDirection"] as? Int,
          let total = object["maximumCumulativePlaintextBytesPerDirection"] as? Int,
          records > 0, total > 0,
          let vectors = object["vectors"] as? [[String: Any]], vectors.count == 2 else {
        throw RecordFixtureError.failed("invalid independent fixed vector")
    }
    let key = SymmetricKey(data: try vectorHex(object, "sessionKeyHex"))
    let binding = try ClusterRecordBinding(epoch: epoch,
        planSHA256: vectorHex(object, "planSHA256Hex"),
        membershipTranscriptSHA256: vectorHex(object, "membershipTranscriptSHA256Hex"))
    let limits = try ClusterRecordLimits(maximumPlaintextBytes: maximum,
        maximumRecordsPerDirection: UInt64(records),
        maximumCumulativePlaintextBytesPerDirection: UInt64(total))
    let plaintext = try vectorHex(object, "plaintextHex")
    try require(try binding.canonicalBytes == vectorHex(object, "bindingHex"), "independent binding bytes")
    try require(try limits.canonicalBytes == vectorHex(object, "limitsHex"), "independent limits bytes")
    var seen = Set<Int>()
    for vector in vectors {
        guard let rank = vector["rank"] as? Int, (0...1).contains(rank), seen.insert(rank).inserted,
              let typeValue = vector["recordType"] as? Int, (1...10).contains(typeValue),
              let type = ClusterRecordType(rawValue: UInt8(typeValue)) else {
            throw RecordFixtureError.failed("invalid vector rank/type")
        }
        let request: UUID?
        if let value = vector["requestID"] as? String {
            guard let parsed = UUID(uuidString: value) else { throw RecordFixtureError.failed("vector request UUID") }
            request = parsed
        } else {
            try require(vector["requestID"] is NSNull, "missing explicit vector setup scope")
            request = nil
        }
        let context = try ClusterRecordContext(requestID: request, type: type,
            expectationSHA256: vectorHex(object, "expectationSHA256Hex"))
        try require(try context.canonicalBytes == vectorHex(vector, "contextHex"), "independent context bytes")
        let state = try ClusterRecordState(sessionKey: key, binding: binding, localRank: rank, limits: limits)
        let work = try state.beginSeal(byteCount: plaintext.count, context: context)
        let keyBytes = work.key.withUnsafeBytes { Data($0) }
        try require(try keyBytes == vectorHex(vector, "derivedKeyHex"), "independent HKDF directional key")
        try require(try work.authenticatedData == vectorHex(vector, "aadHex"), "independent AAD bytes")
        try require(try work.header.encoded == vectorHex(vector, "headerHex"), "independent header bytes")
        try require(try work.header.nonceBytes == vectorHex(vector, "nonceHex"), "independent nonce bytes")
        state.fail(operation: work.id)
        let sender = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding, localRank: rank, limits: limits)
        let receiver = try ClusterAuthenticatedRecordChannel(sessionKey: key, binding: binding, localRank: 1 - rank, limits: limits)
        let expected = try vectorHex(vector, "sealedRecordHex")
        let sealed = try sender.seal(plaintext, context: context)
        try require(sealed == expected, "CryptoKit seal differs from independent OpenSSL vector")
        try require(try receiver.open(expected, expecting: context) == plaintext, "independent vector authenticated open")
        try require(try Data(sealed.dropFirst(24).dropLast(16)) == vectorHex(vector, "ciphertextHex"),
            "independent ciphertext bytes")
        try require(try Data(sealed.suffix(16)) == vectorHex(vector, "tagHex"), "independent tag bytes")
    }
    try require(seen == Set([0, 1]), "independent vector direction coverage")
}
