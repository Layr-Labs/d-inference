import Foundation
import MLX
import Darwin

@main
struct Main {
    static func main() {
        do { try run() }
        catch { log("cluster-inference: \(error)"); exit(1) }
    }

    static func run() throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        // Covers initialization too, so a missing rank cannot wait indefinitely.
        alarm(UInt32(options.timeoutSeconds))
        defer { alarm(0) }
        if options.mode == .workerProtocolCheck {
            try checkWorkerProtocol()
            return
        }
        if options.mode == .adapterCheck {
            try checkGemmaPartitionPlan()
            try checkPartitionStorage()
            return
        }
        // Install MLX's error handler before calling Cmlx directly.
        _ = MLXArray(0)
        if options.mode == .gemmaLoaderCheck {
            try checkGemmaLoader(options)
            return
        }
        if options.mode == .capability {
            try emitJSON(["jacclAvailable": Collective.jacclAvailable])
            guard Collective.jacclAvailable else { throw ProbeError("JACCL is unavailable") }
            return
        }
        if options.mode == .loaderParity {
            try checkDirectShardLoader(options)
            return
        }
        if options.mode == .operatorParity {
            try checkFFNBranchPrecision()
            try checkPrecisionProjection()
            try checkQwenMoEPartitionPlan()
            try checkQwenCheckpointComposition()
            try checkTensorSelections()
            try checkAttentionPartition()
            try checkGDNPartition()
            try checkExpertPartition()
            try checkQwenMoEBoundary()
            try checkGemmaMoEBoundary()
            return
        }
        if options.mode == .tokenSelectionCheck {
            try checkTokenSelection(collective: Collective(transport: options.transport))
            return
        }
        if options.mode.isWorker {
            try runWorkerSession(options)
            return
        }
        let collective = try options.mode == .ffnTP ? Collective(transport: options.transport) : nil
        log("Loading \(options.synthetic ? "synthetic fixture " + options.syntheticProfile : options.modelDirectory!.path)")
        let start = DispatchTime.now().uptimeNanoseconds
        let loaded = try loadModel(options, partitionRank: collective?.rank)
        let loadTime = secondsSince(start)
        if options.attentionOutputPrecision != .native && (collective == nil || options.partition == .ffn) {
            try attachAttentionOutputPrecision(model: loaded.model, layers: loaded.layerCount,
                                                precision: options.attentionOutputPrecision)
        }
        let prompt = try promptTokens(options: options, vocabularySize: loaded.vocabularySize)
        let teacher = try teacherTokens(options: options, vocabularySize: loaded.vocabularySize)
        guard !options.hasRoutingDiagnostic || prompt.count <= 512 else {
            throw ProbeError("Routing capture is limited to 512 actual prompt tokens")
        }
        guard !options.gemmaDiagnostic || prompt.count <= 128 else {
            throw ProbeError("Gemma diagnostic capture is limited to128 actual prompt tokens")
        }
        let routingIdentity = try options.hasRoutingDiagnostic
            ? qwenRoutingIdentity(loaded: loaded, options: options, prompt: prompt, teacher: teacher) : [:]
        let routingTrace = try options.routingFile.map { _ in
            try attachQwenMoERouterTrace(model: loaded.model)
        }
        let routingReplay = try options.routingReplayFile.map { file in
            try attachQwenMoERoutingReplay(model: loaded.model, referenceURL: file,
                                           expectedIdentity: routingIdentity)
        }
        if let collective {
            let agreement = try JSONSerialization.data(withJSONObject: [
                "config": loaded.configHash, "seed": String(options.seed), "prompt": prompt,
                "teacher": teacher ?? [], "decode": options.decodeCount,
                "teacherForced": teacher != nil,
                "tokenSelectionPolicy": "rank0-greedy",
                "syntheticDType": options.synthetic ? options.syntheticDType : "none",
                "syntheticProfile": options.synthetic ? options.syntheticProfile : "none",
                "feedForwardKind": loaded.feedForwardKind,
                "attentionOutputPrecision": options.attentionOutputPrecision.rawValue,
                "ffnBranchPrecision": options.ffnBranchPrecision.rawValue,
                "executionPath": options.executionPath.rawValue,
                "chunk": options.chunkSize, "repeats": options.repeats, "warmups": options.warmups,
                "collectLogits": options.logitsFile != nil,
                "collectRouting": options.routingFile != nil,
                "replayRouting": options.routingReplayFile != nil,
                "gemmaDiagnosticScheduleEnabled": options.gemmaDiagnostic,
                "gemmaBoundaryTraceEnabled": options.gemmaBoundaryFile != nil,
                "routingReplaySHA256": routingReplay?.referenceSHA256 ?? "none",
                "partitionPlan": loaded.partitionPlan?.fingerprint ?? "none",
                "embeddingDType": loaded.embeddingActivationDType,
                "scaleDTypes": loaded.ffnScaleDTypes,
                "modelFamily": loaded.family.rawValue,
                "parameterLayouts": loaded.partitionStorage?.ranks.map(\.parameterLayoutSHA256) ?? [loaded.parameterLayoutSHA256],
                "partitionStorage": try loaded.partitionStorage?.fingerprint ?? "none",
                "bf16ConversionEnabled": loaded.bf16ConversionEnabled,
                "transport": collective.transportLabel,
                "verifiedAggregate": loaded.directShardLoad?.verifiedAggregateSHA256 ?? "unverified-synthetic",
            ], options: [.sortedKeys])
            try collective.requireAgreement(agreementFingerprint(agreement))
            guard let plan = loaded.partitionPlan else { throw ProbeError("Missing collective execution plan") }
            try attachPartitionReductions(model: loaded.model, plan: plan, collective: collective,
                                           gemmaTrace: loaded.gemmaTrace)
        }
        if options.mode == .localParity {
            let fixedTeacher = teacher ?? (0..<(options.decodeCount - 1)).map {
                3 + (($0 * 13 + 9) % (loaded.vocabularySize - 3))
            }
            let baseline = try execute(loaded: loaded, prompt: prompt, teacher: fixedTeacher,
                                       options: options, iteration: 0, collectLogits: true)
            if loaded.feedForwardKind == "moe" {
                let shards = try (0..<2).map { try loadModel(options, partitionRank: $0) }
                try combineLoadedShards(into: loaded, shards: shards)
            } else {
                try installLocalFFNOracle(model: loaded.model, expectedLayers: loaded.layerCount)
            }
            let partitioned = try execute(loaded: loaded, prompt: prompt, teacher: fixedTeacher,
                                          options: options, iteration: 0, collectLogits: true)
            let result = try compare(baseline, partitioned)
            try emitJSON(result)
            guard result.passed else { throw ProbeError("Local full-model FFN partition parity failed") }
            return
        }
        Memory.clearCache()
        for index in 0..<options.warmups {
            collective?.barrier()
            _ = try execute(loaded: loaded, prompt: prompt, teacher: teacher,
                            options: options, iteration: -index - 1, collectLogits: false, collective: collective)
        }
        var runs: [RunResult] = []
        var lastLogits: [[Float]] = []
        for index in 0..<options.repeats {
            collective?.barrier()
            let execution = try execute(loaded: loaded, prompt: prompt, teacher: teacher,
                                        options: options, iteration: index,
                                        collectLogits: options.logitsFile != nil, collective: collective)
            runs.append(execution.result)
            lastLogits = execution.logits
            log("rank \(collective?.rank ?? 0) run \(index): prefill \(execution.result.prefillTokensPerSecond) TPS; decode \(execution.result.decodeTokensPerSecond ?? 0) TPS")
        }
        try routingReplay?.validateComplete()
        if options.hasRoutingDiagnostic || options.gemmaDiagnostic {
            guard runs.count == 1, runs[0].decodeInputTokens == teacher else {
                throw ProbeError("Routing diagnostic did not consume the bound teacher history")
            }
        }
        if let file = options.gemmaBoundaryFile, let trace = loaded.gemmaTrace {
            let identity: [String: String] = [
                "configurationSHA256": loaded.configHash, "syntheticProfile": options.syntheticProfile,
                "syntheticDType": options.syntheticDType, "ffnBranchPrecision": options.ffnBranchPrecision.rawValue,
                "seed": String(options.seed), "promptSHA256": sha256(try JSONEncoder().encode(prompt)),
                "teacherSHA256": sha256(try JSONEncoder().encode(teacher!)), "chunkSize": String(options.chunkSize),
                "rank": String(collective?.rank ?? 0), "worldSize": String(collective?.size ?? 1),
                "partition": loaded.partitionPlan?.kind.rawValue ?? "none",
                "partitionPlanSHA256": loaded.partitionPlan?.fingerprint ?? "none",
            ]
            try trace.write(to: file, identity: identity, expectedTokens: prompt.count + options.decodeCount - 1)
        }
        if let file = options.logitsFile {
            // A caller running both ranks must supply distinct paths.
            try JSONEncoder().encode(lastLogits).write(to: file, options: [.atomic])
        }
        if let file = options.routingFile, let routingTrace {
            try routingTrace.write(to: file, identity: routingIdentity.merging([
                "generatedTokensSHA256": sha256(try JSONEncoder().encode(runs.last!.generatedTokens)),
                "rank": String(collective?.rank ?? 0),
                "worldSize": String(collective?.size ?? 1),
                "partition": loaded.partitionPlan?.kind.rawValue ?? "none",
                "partitionPlanSHA256": loaded.partitionPlan?.fingerprint ?? "none",
            ], uniquingKeysWith: { _, new in new }))
        }
        let report = Report(mode: options.mode.rawValue, modelFamily: loaded.family.rawValue, model: loaded.label,
                            configurationSHA256: loaded.configHash, rank: collective?.rank ?? 0,
                            worldSize: collective?.size ?? 1,
                            promptSource: options.tokensFile == nil ? "synthetic-token-ids" : "token-file",
                            teacherForced: teacher != nil, chunkSize: options.chunkSize,
                            loadSeconds: loadTime, syntheticWeights: options.synthetic,
                            shardedFFNs: collective == nil ? 0 : loaded.layerCount,
                            seed: options.seed,
                            timestamp: Date().ISO8601Format(),
                            promptSHA256: sha256(try JSONEncoder().encode(prompt)),
                            teacherSHA256: try teacher.map { sha256(try JSONEncoder().encode($0)) },
                            embeddingActivationDType: loaded.embeddingActivationDType,
                            ffnScaleDTypes: loaded.ffnScaleDTypes,
                            parameterLayoutSHA256: loaded.parameterLayoutSHA256,
                            bf16ConversionEnabled: loaded.bf16ConversionEnabled,
                            throughputMeasurementValid: !(collective != nil && options.logitsFile != nil)
                                && !(collective?.correctnessOnly ?? false) && !options.hasRoutingDiagnostic && !options.gemmaDiagnostic,
                            transport: collective?.transportLabel ?? "none",
                            correctnessOnly: (collective?.correctnessOnly ?? false) || options.hasRoutingDiagnostic || options.gemmaDiagnostic,
                            directShardLoad: loaded.directShardLoad,
                            partition: loaded.partitionPlan?.kind.rawValue ?? "none",
                            partitionPlanSHA256: loaded.partitionPlan?.fingerprint,
                            tokenSelectionPolicy: collective == nil ? "local-greedy" : "rank0-greedy",
                            vocabularySize: loaded.vocabularySize,
                            syntheticDType: options.synthetic ? options.syntheticDType : nil,
                            syntheticProfile: options.synthetic ? options.syntheticProfile : nil,
                            feedForwardKind: loaded.feedForwardKind,
                            attentionOutputPrecision: options.attentionOutputPrecision.rawValue,
                            ffnBranchPrecision: options.ffnBranchPrecision.rawValue,
                            executionPath: options.executionPath.rawValue,
                            routingTraceEnabled: options.routingFile == nil ? nil : true,
                            routingReplayEnabled: options.routingReplayFile == nil ? nil : true,
                            gemmaDiagnosticScheduleEnabled: options.gemmaDiagnostic ? true : nil,
                            gemmaBoundaryTraceEnabled: options.gemmaBoundaryFile == nil ? nil : true,
                            partitionStorage: loaded.partitionStorage, runs: runs)
        try emitJSON(report)
        collective?.barrier()
    }
}
