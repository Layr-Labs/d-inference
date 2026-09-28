import Foundation

func checkGemmaMetadataRefusals(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    for (key, value) in ["num_hidden_layers": 15, "num_kv_shared_layers": 1,
                         "hidden_size_per_layer_input": 1, "top_k_experts": 4] {
        let changed = try input.changedJSON(input.configuration) { root in
            var text = root["text_config"] as! [String: Any]; text[key] = value; root["text_config"] = text
        }
        try checks.refuses("Gemma geometry changed: " + key) { _ = try Gemma4TextMetadata.decode(changed) }
    }
    let booleanDimension = try input.changedJSON(input.configuration) { root in
        var text = root["text_config"] as! [String: Any]; text["num_kv_shared_layers"] = false; root["text_config"] = text
    }
    try checks.refuses("boolean cannot replace integer zero") { _ = try Gemma4TextMetadata.decode(booleanDimension) }
    let badPhase = try input.changedJSON(input.configuration) { root in
        var text = root["text_config"] as! [String: Any]
        var kinds = text["layer_types"] as! [String]; kinds.swapAt(4, 5); text["layer_types"] = kinds; root["text_config"] = text
    }
    try checks.refuses("global attention phase changed") { _ = try Gemma4TextMetadata.decode(badPhase) }
    let expertOverride = try input.changedJSON(input.configuration) { root in
        var table = root["quantization"] as! [String: Any]
        table["language_model.model.layers.0.experts.switch_glu.gate_proj"] = ["bits": 8, "group_size": 64]
        root["quantization"] = table
    }
    try checks.refuses("expert override changes native geometry policy") { _ = try Gemma4TextMetadata.decode(expertOverride) }
    let droppedOverride = try input.changedJSON(input.configuration) { root in
        var table = root["quantization"] as! [String: Any]
        table.removeValue(forKey: "language_model.model.layers.0.router.proj"); root["quantization"] = table
    }
    try checks.refuses("shared/router override missing") { _ = try Gemma4TextMetadata.decode(droppedOverride) }
    let fractionalBits = try input.changedJSON(input.configuration) { root in
        var table = root["quantization_config"] as! [String: Any]
        table["bits"] = 4.5; root["quantization_config"] = table
    }
    try checks.refuses("fractional quantization bits") { _ = try Gemma4TextMetadata.decode(fractionalBits) }
    try checks.refuses("same semantic config with changed raw identity") {
        _ = try Gemma4ArtifactMetadata.admit(configuration: input.configuration + Data([32]), manifest: input.manifest,
            index: input.index, headers: input.headers)
    }
    try checks.refuses("missing captured shard header") {
        _ = try Gemma4ArtifactMetadata.admit(configuration: input.configuration, manifest: input.manifest,
            index: input.index, headers: Array(input.headers.dropLast()))
    }
    let declared = try JSONDecoder().decode(CheckpointManifest.self, from: input.manifest)
    let wrongIndex = try input.changedJSON(input.index) { root in
        var table = root["weight_map"] as! [String: String]
        table["language_model.model.embed_tokens.weight"] = "model-00003-of-00003.safetensors"; root["weight_map"] = table
    }
    try checks.refuses("index/header source file mismatch") {
        _ = try LayerStageCapturedTensorHeaders.parse(manifest: declared, index: wrongIndex, headers: input.headers)
    }
    try checks.refuses("duplicate captured header") {
        _ = try LayerStageCapturedTensorHeaders.parse(manifest: declared, index: input.index,
            headers: [input.headers[0], input.headers[0], input.headers[2]])
    }
    try checks.refuses("duplicate header JSON member") {
        var headers = input.headers
        headers[0] = .init(sourceFile: headers[0].sourceFile, data: Data("{\"same\":1,\"same\":2}".utf8))
        _ = try LayerStageCapturedTensorHeaders.parse(manifest: declared, index: input.index, headers: headers)
    }
    try checks.refuses("fractional header dimension syntax") {
        var headers = input.headers
        headers[0] = .init(sourceFile: headers[0].sourceFile,
            data: Data("{\"__metadata__\":{\"format\":\"mlx\"},\"model.weight\":{\"dtype\":\"BF16\",\"shape\":[1.0],\"data_offsets\":[0,2]}}".utf8))
        _ = try LayerStageCapturedTensorHeaders.parse(manifest: declared, index: input.index, headers: headers)
    }
}
