import Darwin
import Foundation
import MLX

/// One process owns one loaded model for an epoch. Any error is fatal: the
/// supervisor must retire all ranks before admitting work into a new epoch.
func runWorkerSession(_ options: Options) throws {
    guard let epoch = options.epoch else { throw ProbeError("Worker epoch is required") }
    let collective = try options.mode == .workerTP ? Collective(transport: options.transport) : nil
    let loaded = try loadModel(options, partitionRank: collective?.rank)
    if options.attentionOutputPrecision != .native && (collective == nil || options.partition == .ffn) {
        try attachAttentionOutputPrecision(model: loaded.model, layers: loaded.layerCount,
                                            precision: options.attentionOutputPrecision)
    }
    let identity = try WorkerIdentity(loaded: loaded, options: options, collective: collective)
    let identityHash = sha256(try canonicalJSONData(identity))
    let limits = try WorkerLimits(loaded: loaded, idleTimeoutSeconds: options.timeoutSeconds)
    if let collective {
        // Include epoch and limits so no cohort can cross-wire a previous worker
        // or enter the model with different admission/idle assumptions.
        let agreement = Data((epoch + ":" + identityHash + ":" + sha256(try canonicalJSONData(limits))).utf8)
        try collective.requireAgreement(agreementFingerprint(agreement))
        guard let plan = loaded.partitionPlan else { throw ProbeError("Missing worker partition plan") }
        try attachPartitionReductions(model: loaded.model, plan: plan, collective: collective)
    }
    Memory.clearCache()
    let rank = collective?.rank ?? 0
    let modelLoadID = UUID().uuidString.lowercased()
    try emitJSON(WorkerReady(epoch: epoch, rank: rank, worldSize: collective?.size ?? 1,
                            pid: Int(ProcessInfo.processInfo.processIdentifier), modelLoadID: modelLoadID,
                            identity: identity, identitySHA256: identityHash,
                            parameterLayoutSHA256: loaded.parameterLayoutSHA256,
                            partitionStorage: loaded.partitionStorage, limits: limits))
    var sequence = try WorkerSequence(epoch: epoch)
    let reader = WorkerLineReader()
    while true {
        alarm(UInt32(options.timeoutSeconds))
        guard let line = try reader.next() else {
            throw ProbeError("Worker input closed without an agreed shutdown")
        }
        let command = try WorkerCommand.decode(line)
        try sequence.accept(command: command, vocabularySize: loaded.vocabularySize,
                            maxContextTokens: limits.maxContextTokens)
        switch command {
        case .infer(let request):
            alarm(UInt32(request.timeoutSeconds))
        case .shutdown:
            alarm(UInt32(options.timeoutSeconds))
        }
        let canonical = try command.canonicalData()
        try collective?.requireAgreement(agreementFingerprint(canonical))
        switch command {
        case .shutdown(let request):
            collective?.barrier()
            try emitJSON(WorkerStopped(epoch: epoch, rank: rank, sequence: request.sequence))
            return
        case .infer(let request):
            let requestHash = sha256(canonical)
            try emitJSON(WorkerAccepted(epoch: epoch, rank: rank, sequence: request.sequence,
                                       requestID: request.requestID, requestSHA256: requestHash,
                                       modelLoadID: modelLoadID))
            // The autorelease scope and execute's local KV/recurrent state keep
            // cache lifetime request-local while the loaded weights remain owned.
            try autoreleasepool {
                var runOptions = options
                runOptions.promptCount = request.prompt.count
                runOptions.chunkSize = request.chunkSize
                runOptions.decodeCount = request.outputTokens
                let execution = try execute(loaded: loaded, prompt: request.prompt,
                    teacher: request.teacherTokens, options: runOptions, iteration: request.sequence,
                    collectLogits: request.captureLogits, collective: collective) { step, token in
                        try emitJSON(WorkerToken(epoch: epoch, rank: rank, sequence: request.sequence,
                                                requestID: request.requestID, step: step, token: token))
                    }
                collective?.barrier()
                try emitJSON(WorkerCompleted(epoch: epoch, rank: rank, sequence: request.sequence,
                    requestID: request.requestID, requestSHA256: requestHash, modelLoadID: modelLoadID,
                    result: execution.result, logits: request.captureLogits ? execution.logits : nil))
            }
        }
    }
}
