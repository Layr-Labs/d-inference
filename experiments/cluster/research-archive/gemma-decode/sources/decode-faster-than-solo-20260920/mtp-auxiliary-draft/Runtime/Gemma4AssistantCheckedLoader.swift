import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXLLM

struct Gemma4AssistantLoadReceipt: Encodable {
    let artifactSHA256: String, configurationSHA256: String, parameterLayoutSHA256: String
    let tensorCount: Int, tensorBytes: Int
    let readAccounting: CheckpointAlignedReadAccounting
    let constructorQuantizedParametersUnmaterialized: Int
    let allActualParametersReplaced = true
    let resourceAdmissionEstablishedByReceipt = false
}

struct Gemma4LoadedAssistant {
    let model: Gemma4AssistantDraftModel
    let receipt: Gemma4AssistantLoadReceipt
}

/// The caller already holds the existing native device lifetime. Local `check`
/// MUST be the target owner with this exact auxiliary attached; remote `check`
/// MUST call this auxiliary's checkStandalone. requireObserved refuses a no-op
/// at every phase transition. There is no unchecked .load(from:) fallback.
func loadRegisteredGemma4Assistant(directory: URL, artifact: Gemma4AssistantArtifact,
    auxiliary: Gemma4MTPAuxiliaryOwner, check: () throws -> Void
) throws -> Gemma4LoadedAssistant {
    try withoutActuallyEscaping(check) { borrowed in
        try MLX.withError { native in
            func checked() throws { try native.check(); try borrowed(); try auxiliary.requireObserved(); try native.check() }
            do {
                try checked()
                let checkpoint = try VerifiedCheckpoint(directory:directory,configurationData:artifact.configuration,
                    expectedAggregateSHA256:Gemma4AssistantArtifact.aggregateSHA256,maximumPayloadBytes:236_127_665,
                    expectedManifestSHA256:Gemma4AssistantArtifact.manifestSHA256)
                try checked(); try checkpoint.requireConfiguration(artifact.configuration)
                let descriptors = try tensorDescriptors(checkpoint:checkpoint)
                guard Set(descriptors.keys) == Set(artifact.tensors.map(\.name)), descriptors.count == 94 else {
                    throw ProbeError("Actual assistant tensor inventory differs from registered header")
                }
                for tensor in artifact.tensors {
                    guard let value = descriptors[tensor.name], value.file.path == "model.safetensors",
                          value.shape == tensor.shape, value.offset == tensor.offset, value.byteCount == tensor.bytes,
                          value.dtype == (tensor.sourceDType == "U32" ? .uint32 : .bfloat16) else {
                        throw ProbeError("Actual assistant descriptor differs")
                    }
                }
                try checkpoint.checkUnchanged(); try checkpoint.bypassTensorPayloadCache(); try checked()
                let configuration = try JSONDecoder().decode(Gemma4AssistantConfiguration.self,from:artifact.configuration)
                let base = try JSONDecoder().decode(BaseConfiguration.self,from:artifact.configuration)
                guard !configuration.useOrderedEmbeddings, configuration.backboneHiddenSize == 2816,
                      configuration.textConfig.hiddenSize == 1024, configuration.textConfig.vocabSize == 262144,
                      configuration.textConfig.numHiddenLayers == 4, configuration.textConfig.numKvSharedLayers == 4,
                      configuration.textConfig.tieWordEmbeddings,
                      let policy = base.perLayerQuantization else { throw ProbeError("Actual assistant configuration differs") }
                try auxiliary.beginConstruction(); try checked()
                // Keep constructor references inside this helper. None escape
                // into loading except the final quantized module parameters.
                func prepare() throws -> Gemma4AssistantDraftModel {
                    let model = try Gemma4AssistantDraftModel(config:configuration)
                    try checked()
                    let plain = Dictionary(uniqueKeysWithValues:model.parameters().flattened())
                    let expectedPlain = artifact.tensors.filter { !$0.name.hasSuffix(".scales") && !$0.name.hasSuffix(".biases") }
                    guard Set(plain.keys) == Set(expectedPlain.map(\.name)) else { throw ProbeError("Assistant unquantized constructor inventory differs") }
                    for item in expectedPlain {
                        var shape = item.shape
                        if item.sourceDType == "U32" { shape[shape.count-1] *= 8 }
                        guard let parameter = plain[item.name], parameter.shape == shape,
                              [.float16,.bfloat16,.float32].contains(parameter.dtype) else {
                            throw ProbeError("Assistant unquantized constructor shape differs")
                        }
                        if item.sourceDType == "U32", try parameter.evaluatedBufferInfo() != nil {
                            throw ProbeError("Assistant random matrix materialized before replacement")
                        }
                    }
                    var resolved: [String:BaseConfiguration.Quantization] = [:]
                    for (path, _) in model.leafModules().flattened() where artifact.quantizedPaths.contains(path) {
                        guard let q = policy.quantization(layer:path), q.bits == 4, q.groupSize == 64, q.mode == .affine else {
                            throw ProbeError("Assistant original affine quantizer policy differs")
                        }
                        resolved[path] = q
                    }
                    guard Set(resolved.keys) == artifact.quantizedPaths else { throw ProbeError("Assistant quantizer module coverage differs") }
                    quantize(model:model) { path,_ in resolved[path]?.asTuple }
                    try checked()
                    let packed = Dictionary(uniqueKeysWithValues:model.parameters().flattened())
                    guard Set(packed.keys) == Set(artifact.tensors.map(\.name)) else { throw ProbeError("Assistant packed constructor inventory differs") }
                    var lazy = 0
                    for item in artifact.tensors {
                        guard let parameter = packed[item.name], parameter.shape == item.shape,
                              item.sourceDType != "U32" || parameter.dtype == .uint32 else {
                            throw ProbeError("Assistant packed constructor shape/class differs")
                        }
                        let parent = item.name.split(separator:".").dropLast().joined(separator:".")
                        if artifact.quantizedPaths.contains(parent) {
                            guard try parameter.evaluatedBufferInfo() == nil else {
                                throw ProbeError("Assistant quantization graph evaluated before exact source replacement")
                            }
                            lazy += 1
                        }
                    }
                    try checked(); try auxiliary.prepared(unmaterializedPackedCount:lazy); try checked()
                    return model
                }
                let model = try prepare()
                var accounting = CheckpointAlignedReadAccounting(), total = 0
                for tensor in artifact.tensors {
                    try autoreleasepool {
                        try auxiliary.beforeItem(source:"assistant",name:tensor.name,shape:tensor.shape,bytes:tensor.bytes)
                        try checked()
                        guard let descriptor = descriptors[tensor.name] else { throw ProbeError("Assistant verified source disappeared") }
                        let read = try descriptor.read(.all), array = read.array
                        try checked()
                        let sanitized = try model.sanitize(weights:[tensor.name:array])
                        guard sanitized.count == 1, let value = sanitized[tensor.name], value === array,
                              value.shape == tensor.shape, value.dtype == descriptor.dtype,
                              value.nbytes == tensor.bytes, read.copiedBytes == tensor.bytes else {
                            throw ProbeError("Assistant actual sanitize/read geometry differs")
                        }
                        eval(value); Stream.gpu.synchronize(); try checked()
                        guard let storage = try value.evaluatedBufferInfo(), storage.isUnique,
                              storage.isRowContiguous, storage.dataOffset == 0, storage.dataElements == value.size,
                              storage.allocatedBytes >= value.nbytes,
                              storage.allocatedBytes <= (try QwenResidentResourceEnvironment.allocationBound(value.nbytes)),
                              let part = read.readAccounting, part.selectedBytes == tensor.bytes else {
                            throw ProbeError("Assistant payload lacks compact owned storage/read accounting")
                        }
                        try model.update(parameters:ModuleParameters.unflattened([tensor.name:value]),verify:[.noUnusedKeys,.shapeMismatch])
                        total = try QwenLongPrefillCheckedBytes.sum([total,tensor.bytes]); try accounting.merge(part)
                        try checked()
                    }
                    // Actual read Data/scratch/sanitize/update scope is gone.
                    try checked(); try auxiliary.afterItem(source:"assistant",name:tensor.name); try checked()
                }
                let actual = Dictionary(uniqueKeysWithValues:model.parameters().flattened())
                guard actual.count == 94, Set(actual.keys) == Set(artifact.tensors.map(\.name)),
                      total == 236_114_440, accounting.selectedBytes == total else { throw ProbeError("Assistant final parameter coverage differs") }
                for tensor in artifact.tensors {
                    guard let value = actual[tensor.name], value.shape == tensor.shape, value.nbytes == tensor.bytes,
                          value.dtype == (tensor.sourceDType == "U32" ? .uint32 : .bfloat16) else { throw ProbeError("Assistant final native parameter identity differs") }
                }
                // The first whole-module eval is only after every constructor
                // parameter is gone. Keep the constructor reserve through it.
                model.freeze(); eval(model); Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                try checkpoint.checkUnchanged()
                guard model.trainableParameters().flattened().isEmpty else { throw ProbeError("Assistant parameters are not frozen") }
                let receipt = Gemma4AssistantLoadReceipt(artifactSHA256:checkpoint.aggregate,
                    configurationSHA256:checkpoint.configurationSHA256,parameterLayoutSHA256:artifact.parameterLayoutSHA256,
                    tensorCount:94,tensorBytes:total,readAccounting:accounting,constructorQuantizedParametersUnmaterialized:69)
                try auxiliary.assistantLoaded(receipt); try checked()
                return .init(model:model,receipt:receipt)
            } catch {
                auxiliary.poison()
                try native.check(); throw error
            }
        }
    }
}
