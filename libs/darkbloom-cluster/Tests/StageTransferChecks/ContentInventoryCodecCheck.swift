import Foundation

/// Five tensors in two files. Offsets within a file do not follow name order,
/// and the second file has a gap, as real safetensors files do.
enum TinyContentInventory {
    static let lines = [
        "model.embed.weight|U32|4,2|32|model-00001-of-00002.safetensors|96|8a1eed22144c3f04485a69eea62bfd3fa1026de39dc252b77ba9b1f3f08b00ec",
        "model.layers.0.scales|BF16|4,1|8|model-00001-of-00002.safetensors|128|6c00c076acc9c2f4b6a0c6403e07c7eb8ca220a10b4750c239cd013f24a8778c",
        "model.layers.0.A_log|F32|3|12|model-00001-of-00002.safetensors|136|bb106c572b630c0b2e29c926c83b2c0ef407decaca1d77c7d6cdd570765426ba",
        "model.layers.1.weight|U32|2,2,2|32|model-00002-of-00002.safetensors|64|77ea7eee3d80b1a38f83906dd3048e2689457eb90e18a7d12f839c5ae37106a2",
        "model.norm.weight|F16|6|12|model-00002-of-00002.safetensors|100|733859c1fc6b9331793b2952dde66f89cdd4d513d04d59d7b07bd3912098e79b",
    ]

    static func document(_ lines: [String] = lines, count: String? = nil) -> Data {
        Data(([LayerStageTensorContentInventory.schema, count ?? String(lines.count)] + lines)
            .map { $0 + "\n" }.joined().utf8)
    }

    /// One line with one of its seven fields replaced.
    static func line(_ index: Int, field: Int, _ value: String) -> [String] {
        var result = lines
        var fields = result[index].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        fields[field] = value
        result[index] = fields.joined(separator: "|")
        return result
    }
}

func checkContentInventoryCodec(_ inputs: RetainedQwenInputs, _ checks: StageTransferChecks) throws {
    let document = TinyContentInventory.document()
    let inventory = try LayerStageTensorContentInventory.decode(document)
    // Goldens computed outside Swift from the same five lines.
    try checks.require("canonical encoding and its pin are stable", inventory.encoded() == document
        && document.count == 705
        && inventory.encodedSHA256 == "97d2203b25698e3933bc8a9f22347e5fef14182c8ffa8e204522bd7ed2f5a023")
    try checks.require("decoded records keep every field", inventory.records.count == 5
        && inventory.payloadBytes == 96
        && inventory.records[2].source.layout.canonicalName == "model.layers.0.A_log"
        && inventory.records[2].source.layout.shape == [3] && inventory.records[2].source.layout.sourceDType == "F32"
        && inventory.records[2].source.sourceFile == "model-00001-of-00002.safetensors"
        && inventory.records[2].source.sourceOffset == 136
        && inventory.records[2].contentSHA256 == "bb106c572b630c0b2e29c926c83b2c0ef407decaca1d77c7d6cdd570765426ba")
    try checks.require("records built in code encode to the same document",
        try LayerStageTensorContentInventory(records: inventory.records) == inventory)
    try checks.require("dropping file, offset and content gives the name-ordered layout fingerprint",
        inventory.layoutInventorySHA256 == "d58b83f1e8db59b8a6fba541ac6e90dea5e3298246160e0f21821eed00f33897")

    try checkSourceTensorManifest(inventory, checks)
    try checkRegisteredLayoutProjection(inputs, checks)
    try checkContentInventoryFraming(checks)
    try checkContentInventoryRecords(checks)
    try checkContentInventoryOrder(checks)
}

/// The exact JSON a local load hashes for its source-tensor manifest.
private func checkSourceTensorManifest(_ inventory: LayerStageTensorContentInventory,
                                       _ checks: StageTransferChecks) throws {
    func row(_ name: String, _ file: Int, _ offset: Int, _ shape: String, _ bytes: Int,
             _ source: String, _ loaded: String) -> String {
        #"{"byteCount":\#(bytes),"canonicalPartName":"\#(name)","file":"model-0000\#(file)-of-00002.safetensors","#
            + #""loadedDType":"\#(loaded)","offset":\#(offset),"shape":[\#(shape)],"sourceDType":"\#(source)","sourceName":"\#(name)"}"#
    }
    func expected(_ normLoaded: String) -> Data {
        Data(("[" + [
            row("model.embed.weight", 1, 96, "4,2", 32, "uint32", "uint32"),
            row("model.layers.0.A_log", 1, 136, "3", 12, "float32", "float32"),
            row("model.layers.0.scales", 1, 128, "4,1", 8, "bfloat16", "bfloat16"),
            row("model.layers.1.weight", 2, 64, "2,2,2", 32, "uint32", "uint32"),
            row("model.norm.weight", 2, 100, "6", 12, "float16", normLoaded),
        ].joined(separator: ",") + "]").utf8)
    }
    let converted = try QwenStageSourceTensorManifest.tensors(inventory, bf16ConversionEnabled: true)
    try checks.require("source-tensor manifest is the loader's JSON in name order",
        try canonicalJSONData(converted) == expected("bfloat16")
        && (try QwenStageSourceTensorManifest.fingerprint(inventory, bf16ConversionEnabled: true))
            == "81e0091ae375fbefcbef0f6f091b4eb06c9388af25700d72b4b0638a51011fa8")
    let unconverted = try QwenStageSourceTensorManifest.tensors(inventory, bf16ConversionEnabled: false)
    try checks.require("source-tensor manifest keeps float16 without the conversion policy",
        try canonicalJSONData(unconverted) == expected("float16")
        && (try QwenStageSourceTensorManifest.fingerprint(inventory, bf16ConversionEnabled: false))
            == "d57ff32d0a9df44653124a05d5a78181717ec874dbfac5e6a79c52e064dca2c4")
}

/// The retained registered layouts, given invented locations and digests,
/// must project back to the inventory fingerprints the specification pins.
private func checkRegisteredLayoutProjection(_ inputs: RetainedQwenInputs, _ checks: StageTransferChecks) throws {
    for (label, profile, pinned) in [
        ("9B", inputs.nine, "4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51"),
        ("27B", inputs.twentySeven, "ebe2ded36d62a6f83bfa1c1b69951a8e24e9e63094745eb60c4bb353c8951624"),
    ] {
        var offset = 8
        // Reverse name order within the file: the projection must not depend on record order.
        let records = try profile.canonicalTensors.sorted { $0.name > $1.name }.map { tensor -> LayerStageTensorContentRecord in
            let layout = try LayerStageTensorLayout(canonicalName: tensor.name, shape: tensor.shape,
                sourceDType: tensor.sourceDType, byteCount: tensor.byteCount)
            let source = try LayerStageSourceTensor(layout: layout, sourceFile: "invented.safetensors", sourceOffset: offset)
            offset += tensor.byteCount
            return try .init(source: source, contentSHA256: sha256(Data(tensor.name.utf8)))
        }
        let inventory = try LayerStageTensorContentInventory(records: records)
        try checks.require("registered \(label) layouts project to the pinned inventory fingerprint",
            inventory.layoutInventorySHA256 == pinned
            && (try LayerStageTensorContentInventory.decode(inventory.encoded())) == inventory)
    }
}

private func checkContentInventoryFraming(_ checks: StageTransferChecks) throws {
    let document = TinyContentInventory.document()
    func decode(_ data: Data) throws { _ = try LayerStageTensorContentInventory.decode(data) }
    try checks.refuses("document over the encoded byte limit", because: "exceeds its encoded byte limit") {
        try decode(document + Data(repeating: 10, count: LayerStageTensorContentInventory.maximumEncodedBytes))
    }
    try checks.refuses("empty document", because: "does not end with a newline") { try decode(Data()) }
    try checks.refuses("missing final newline", because: "does not end with a newline") {
        try decode(document.dropLast())
    }
    try checks.refuses("schema line only", because: "unknown schema or no record count") {
        try decode(Data((LayerStageTensorContentInventory.schema + "\n").utf8))
    }
    try checks.refuses("unknown schema version", because: "unknown schema or no record count") {
        try decode(Data(String(decoding: document, as: UTF8.self).replacingOccurrences(of: "inventory-v1", with: "inventory-v2").utf8))
    }
    try checks.refuses("record count with a leading zero", because: "canonical decimals") {
        try decode(TinyContentInventory.document(count: "05"))
    }
    try checks.refuses("record count that is not a number", because: "canonical decimals") {
        try decode(TinyContentInventory.document(count: "five"))
    }
    try checks.refuses("a record after the declared count", because: "truncated or has trailing data") {
        try decode(TinyContentInventory.document(count: "4"))
    }
    try checks.refuses("fewer records than declared", because: "truncated or has trailing data") {
        try decode(TinyContentInventory.document(count: "6"))
    }
    try checks.refuses("blank line after the last record", because: "truncated or has trailing data") {
        try decode(document + Data([10]))
    }
    try checks.refuses("bytes after the last record", because: "truncated or has trailing data") {
        try decode(document + Data("trailing\n".utf8))
    }
}

private func checkContentInventoryRecords(_ checks: StageTransferChecks) throws {
    func decode(_ lines: [String]) throws {
        _ = try LayerStageTensorContentInventory.decode(TinyContentInventory.document(lines))
    }
    let digest = String(repeating: "a", count: 64)
    try checks.refuses("record with six fields", because: "seven fields") {
        var lines = TinyContentInventory.lines
        lines[0] = String(lines[0].dropLast(65))
        try decode(lines)
    }
    try checks.refuses("record with eight fields", because: "seven fields") {
        var lines = TinyContentInventory.lines
        lines[0] += "|" + digest
        try decode(lines)
    }
    try checks.refuses("unknown dtype", because: "unsupported source dtype") {
        try decode(TinyContentInventory.line(0, field: 1, "I64"))
    }
    try checks.refuses("byte count that disagrees with shape and dtype", because: "shape and byte count disagree") {
        try decode(TinyContentInventory.line(4, field: 3, "14"))
    }
    try checks.refuses("dtype width that disagrees with the byte count", because: "shape and byte count disagree") {
        try decode(TinyContentInventory.line(0, field: 1, "BF16"))
    }
    try checks.refuses("dimension with a leading zero", because: "canonical decimals") {
        try decode(TinyContentInventory.line(0, field: 2, "04,2"))
    }
    try checks.refuses("empty shape", because: "canonical decimals") {
        try decode(TinyContentInventory.line(0, field: 2, ""))
    }
    try checks.refuses("zero dimension", because: "invalid name or bounded shape") {
        try decode(TinyContentInventory.line(0, field: 2, "0,2"))
    }
    try checks.refuses("five dimensions", because: "invalid name or bounded shape") {
        try decode(TinyContentInventory.line(0, field: 2, "2,2,2,2,2"))
    }
    try checks.refuses("name outside the tensor name alphabet", because: "invalid name or bounded shape") {
        try decode(TinyContentInventory.line(0, field: 0, "model.embed weight"))
    }
    try checks.refuses("byte count with a plus sign", because: "canonical decimals") {
        try decode(TinyContentInventory.line(0, field: 3, "+32"))
    }
    try checks.refuses("file that is not a safetensors name", because: "Invalid stage source location") {
        try decode(TinyContentInventory.line(0, field: 4, "model-00001-of-00002.bin"))
    }
    try checks.refuses("file in a subdirectory", because: "Invalid stage source location") {
        try decode(TinyContentInventory.line(4, field: 4, "weights/model.safetensors"))
    }
    try checks.refuses("offset inside the safetensors length prefix", because: "Invalid stage source location") {
        try decode(TinyContentInventory.line(0, field: 5, "7"))
    }
    try checks.refuses("offset with a leading zero", because: "canonical decimals") {
        try decode(TinyContentInventory.line(0, field: 5, "096"))
    }
    try checks.refuses("range that overflows", because: "Byte-count sum overflow") {
        try decode(TinyContentInventory.line(4, field: 5, String(Int.max - 4)))
    }
    try checks.refuses("uppercase digest", because: "lowercase SHA-256") {
        try decode(TinyContentInventory.line(0, field: 6, String(repeating: "A", count: 64)))
    }
    try checks.refuses("digest one character short", because: "lowercase SHA-256") {
        try decode(TinyContentInventory.line(0, field: 6, String(repeating: "a", count: 63)))
    }
    try checks.refuses("digest with a non-hex character", because: "lowercase SHA-256") {
        try decode(TinyContentInventory.line(0, field: 6, String(repeating: "a", count: 63) + "g"))
    }
}

private func checkContentInventoryOrder(_ checks: StageTransferChecks) throws {
    func decode(_ lines: [String]) throws {
        _ = try LayerStageTensorContentInventory.decode(TinyContentInventory.document(lines))
    }
    let lines = TinyContentInventory.lines
    try checks.refuses("no records", because: "empty or exceeds its tensor limit") { try decode([]) }
    try checks.refuses("more records than the tensor limit", because: "empty or exceeds its tensor limit") {
        let digest = String(repeating: "b", count: 64)
        try decode((0...LayerStageTensorContentInventory.maximumTensorCount).map {
            "t\($0)|F32|1|4|many.safetensors|\(8 + 4 * $0)|\(digest)"
        })
    }
    try checks.refuses("duplicate tensor name", because: "repeats a tensor name") {
        try decode(TinyContentInventory.line(3, field: 0, "model.embed.weight"))
    }
    try checks.refuses("ranges that overlap within a file", because: "overlap or are out of order within a file") {
        try decode(TinyContentInventory.line(1, field: 5, "127"))
    }
    try checks.refuses("ranges out of order within a file", because: "overlap or are out of order within a file") {
        try decode([lines[1], lines[0], lines[2], lines[3], lines[4]])
    }
    try checks.refuses("files out of order", because: "files are out of order") {
        try decode([lines[3], lines[4], lines[0], lines[1], lines[2]])
    }
    try checks.refuses("a file's records split around another file", because: "files are out of order") {
        try decode([lines[0], lines[3], lines[1], lines[2], lines[4]])
    }
    try checks.refuses("more files than the source file limit", because: "exceeds its source file limit") {
        let digest = String(repeating: "c", count: 64)
        try decode((0...LayerStageTensorContentInventory.maximumSourceFileCount).map {
            "t\($0)|F32|1|4|" + String(format: "f%02d.safetensors", $0) + "|8|\(digest)"
        })
    }
    try checks.refuses("record built with a malformed digest", because: "lowercase SHA-256") {
        let source = try LayerStageTensorContentInventory.decode(TinyContentInventory.document()).records[0].source
        _ = try LayerStageTensorContentRecord(source: source, contentSHA256: "not a digest")
    }
}
