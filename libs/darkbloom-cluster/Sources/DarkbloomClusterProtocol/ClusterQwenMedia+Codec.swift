import Foundation

extension ClusterQwenMedia {
    func wireObject() -> [String: Any] {
        ["contract": Self.contract, "artifactSHA256": artifactSHA256,
         "configurationSHA256": configurationSHA256, "processorSHA256": processorSHA256,
         "processorPolicy": processorPolicy.rawValue, "promptLength": promptLength,
         "promptSHA256": promptSHA256, "positionIDsSHA256": positionIDsSHA256,
         "decodeDeltas": decodeDeltas.map(Int.init), "items": items.map { item -> [String: Any] in
            var value: [String: Any] = ["kind": item.kind.rawValue, "sha256": item.sha256,
                "byteCount": item.byteCount, "decodedPixels": item.decodedPixels, "temporal": item.temporal, "height": item.height,
                "width": item.width, "tokenOffset": item.tokenOffset, "tokenCount": item.tokenCount,
                "patchesSHA256": item.patchesSHA256]
            if let encoded = item.encoded { value["encoded"] = encoded.base64EncodedString() }
            return value
         }]
    }

    static func decode(wire: [String: Any]) throws -> Self {
        var root = WorkerObject(wire)
        try workerRequire(try root.string("contract") == Self.contract, "Unknown Qwen media contract")
        let artifact = try root.string("artifactSHA256"), configuration = try root.string("configurationSHA256")
        let processor = try root.string("processorSHA256")
        let policy: ProcessorPolicy = try root.enumeration("processorPolicy")
        let length = try root.int("promptLength"), prompt = try root.string("promptSHA256")
        let positions = try root.string("positionIDsSHA256"), deltas = try root.ints("decodeDeltas")
        try workerRequire(deltas.count == 1 && deltas.allSatisfy { Int32(exactly: $0) != nil },
            "Invalid Qwen decode delta")
        let objects = try root.objects("items"); try root.finish()
        try workerRequire((1...(maximumImages + maximumVideos)).contains(objects.count), "Invalid Qwen media count")
        var remaining = maximumEncodedBytes
        let items = try objects.map { object -> Item in
            var item = WorkerObject(object)
            var bytes: Data?
            if item.values["encoded"] != nil {
                let text = try item.string("encoded")
                try workerRequire(text.utf8.count <= (remaining + 2) / 3 * 4, "Qwen media base64 bound")
                guard let data = Data(base64Encoded: text), data.count <= remaining else {
                    throw ClusterWorkerProtocolError.invalid("Invalid Qwen media encoding")
                }
                remaining -= data.count; bytes = data
            }
            let value = try Item(kind: item.enumeration("kind"), sha256: item.string("sha256"),
                byteCount: item.int("byteCount"), decodedPixels: item.int("decodedPixels"), encoded: bytes, temporal: item.int("temporal"),
                height: item.int("height"), width: item.int("width"), tokenOffset: item.int("tokenOffset"),
                tokenCount: item.int("tokenCount"), patchesSHA256: item.string("patchesSHA256"))
            try item.finish(); return value
        }
        let result = Self(artifactSHA256: artifact, configurationSHA256: configuration,
            processorSHA256: processor, processorPolicy: policy, promptLength: length,
            promptSHA256: prompt, positionIDsSHA256: positions, decodeDeltas: deltas.map(Int32.init), items: items)
        try result.validateStructure()
        return result
    }

    public func encoded() throws -> Data {
        try validateStructure()
        let data = try JSONSerialization.data(withJSONObject: wireObject(), options: [.sortedKeys, .withoutEscapingSlashes])
        try workerRequire(data.count <= Self.maximumEnvelopeBytes, "Qwen media envelope exceeds bound")
        return data
    }

    public static func decodeBounded(_ data: Data) throws -> Self {
        try workerRequire(!data.isEmpty && data.count <= maximumEnvelopeBytes, "Qwen media envelope exceeds bound")
        try validateClusterWorkerJSON(data)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterWorkerProtocolError.invalid("Qwen media envelope must be an object")
        }
        return try decode(wire: value)
    }
}
