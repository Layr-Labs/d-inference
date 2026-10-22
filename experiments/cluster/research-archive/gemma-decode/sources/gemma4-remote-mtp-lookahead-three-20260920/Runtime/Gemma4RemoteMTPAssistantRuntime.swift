import Foundation
import MLX
import MLXNN

struct Gemma4RemoteMTPAssistantSample: Encodable {
    let ordinal: Int, requestID: String, requestSHA256: String, wireScopeSHA256: String
    let originalServiceReleased = true, branchRootsReleased = true
    let targetTokensIndependentlyVerified = false, physicalOwnerRetirementEstablished = false
}
struct Gemma4RemoteMTPAssistantReport: Encodable {
    let schema = "gemma4_remote_mtp_assistant_cohort_v1"
    let configuration: Gemma4RemoteMTPJob, scopeSHA256: String
    let assistantLoad: Gemma4AssistantLoadReceipt, embeddingLoad: Gemma4DraftEmbeddingLoadReceipt
    let samples: [Gemma4RemoteMTPAssistantSample]
    let resources: Gemma4MTPAuxiliaryReceipt
    let warmupRequests = 1, measuredRequests = 3, assistantRank = 0, targetRank = 1
    let fullTargetLoaded = false, modelReleased = true, nativeExecuted = true
    let encryptedRDMAEstablished = false, numericalComparisonPerformed = false, servingEnabled = false
    let physicalProcessOrLeaseRetirementEstablished = false
}

enum Gemma4RemoteMTPAssistantRuntime {
    static func execute(_ input: Gemma4RemoteMTPInput, deadline: UInt64, group: Collective,
        control: Gemma4RemoteMTPCohortControl, lifetime: Gemma4RemoteMTPNativeLifetime,
        check: (Gemma4BenchmarkGuardObservation?) throws -> Void) throws -> Data {
        let benchmark = input.benchmark
        let budget = try Gemma4MTPAuxiliaryBudget(artifact:input.local.assistant,placement:.remoteAssistant,
            requestSHA256:input.resourceRequestSHA256,maximumFrontier:benchmark.requests[0].finalCommittedTokens,
            bound:QwenResidentResourceEnvironment.allocationBound)
        let auxiliary = try Gemma4MTPAuxiliaryOwner(budget:budget,deadline:deadline)
        func checked() throws {
            let observation = Gemma4BenchmarkGuardObservation(mode:.combined,deadline:deadline)
            defer { observation.close() }
            try check(observation); try auxiliary.checkStandalone(observation:observation)
            try check(observation); try observation.finish(deadline:deadline)
        }
        try checked()
        weak var releasedAssistant: Module?
        weak var releasedEmbedding: Gemma4RegisteredDraftEmbedding?
        let result: (Gemma4AssistantLoadReceipt,Gemma4DraftEmbeddingLoadReceipt,[Gemma4RemoteMTPAssistantSample]) = try autoreleasepool {
            let assistant = try loadRegisteredGemma4Assistant(
                directory:URL(fileURLWithPath:input.local.job.assistantModelDirectory,isDirectory:true),
                artifact:input.local.assistant,auxiliary:auxiliary,check:checked)
            lifetime.assistant = assistant.model; releasedAssistant = assistant.model
            let source = try Gemma4RegisteredSource.prepare(directory:URL(fileURLWithPath:benchmark.job.modelDirectory,isDirectory:true),
                artifact:benchmark.artifact,cut:benchmark.job.cut,check:checked)
            let prepared = try Gemma4PreparedDraftEmbedding(source:source)
            guard prepared.identitySHA256 == input.job.embeddingIdentitySHA256 else { throw ProbeError("Remote MTP actual selected embedding identity differs") }
            let embedding = try materializeRegisteredGemma4DraftEmbedding(prepared,
                beforeTensor:auxiliary.beforeEmbedding,afterTensor:auxiliary.afterEmbedding,check:checked)
            lifetime.embedding = embedding; releasedEmbedding = embedding
            try auxiliary.embeddingLoaded(embedding.receipt); try checked()
            let conditioning = embedding.conditioning()
            try control.checkpoint("loaded",ordinal:-1,check:checked,lifetimeCheck:auxiliary.checkControlLifetime)
            var samples: [Gemma4RemoteMTPAssistantSample] = []
            for ordinal in benchmark.requests.indices {
                weak var releasedService: Gemma4MTPPullAssistant?
                try autoreleasepool {
                    let request = benchmark.requests[ordinal]
                    let channel = try Gemma4MTPPullChannel(collective:group,role:.assistant,targetRank:1,scopeSHA256:input.wireScope(ordinal),
                        controlOperations:control.controlOperations,controlLifetimeCheck:auxiliary.checkControlLifetime)
                    let service = try Gemma4MTPPullAssistant(channel:channel,scope:input.requestScope(ordinal),
                        initialFrontier:request.promptCount+1,assistant:assistant.model,conditioning:conditioning,auxiliary:auxiliary,
                        producerCreditPolicy:input.producerCreditPolicy)
                    lifetime.service = service; releasedService = service
                    let completion = try service.run(check:check)
                    guard completion == .finished else { throw ProbeError("Remote MTP assistant request was cancelled") }
                    try Gemma4MTPPullNativeFence.join(check:checked)
                    lifetime.service = nil
                }
                try Gemma4MTPPullNativeFence.join(check:checked)
                guard releasedService == nil else { throw ProbeError("Remote MTP assistant service escaped its request") }
                try control.checkpoint("request-retired",ordinal:ordinal,check:checked,lifetimeCheck:auxiliary.checkControlLifetime)
                let request = benchmark.requests[ordinal]
                samples.append(try .init(ordinal:ordinal,requestID:request.requestID.uuidString.lowercased(),
                    requestSHA256:request.fingerprint,wireScopeSHA256:input.wireScope(ordinal)))
            }
            guard samples.count == 4 else { throw ProbeError("Remote MTP assistant request count differs") }
            return (assistant.receipt,embedding.receipt,samples)
        }
        try Gemma4MTPPullNativeFence.join(check:checked)
        lifetime.assistant = nil; lifetime.embedding = nil
        try Gemma4MTPPullNativeFence.join(check:checked)
        guard releasedAssistant == nil, releasedEmbedding == nil else { throw ProbeError("Remote MTP assistant or embedding remains retained") }
        Memory.clearCache(); try checked()
        let receipt = try auxiliary.completedAfterNativeFence(check:checked)
        try control.checkpoint("models-released",ordinal:-1,check:checked,lifetimeCheck:auxiliary.checkControlLifetime)
        return try canonicalJSONData(Gemma4RemoteMTPAssistantReport(configuration:input.job,scopeSHA256:input.scopeSHA256,
            assistantLoad:result.0,embeddingLoad:result.1,samples:result.2,resources:receipt))
    }
}
