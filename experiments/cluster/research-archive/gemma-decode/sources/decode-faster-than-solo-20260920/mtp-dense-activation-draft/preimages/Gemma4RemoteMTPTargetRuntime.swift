import Foundation
import MLX
import MLXNN

struct Gemma4RemoteMTPTargetReport: Encodable {
    let schema = "gemma4_remote_mtp_target_cohort_v1"
    let configuration: Gemma4RemoteMTPJob, ordinaryJob: Gemma4BenchmarkJob
    let scopeSHA256: String
    let sourceLoad: Gemma4ForwardLoadReceipt
    let samples: [Gemma4RemoteMTPSample]
    let resources: Gemma4BenchmarkResourceReceipt, remoteResources: Gemma4MTPRemoteTargetReceipt
    let files: [Gemma4ShortFile]
    let warmupRequests = 1, measuredRequests = 3, targetRank = 1, assistantRank = 0
    let assistantLoadedOnTarget = false, modelReleased = true, nativeExecuted = true
    let encryptedRDMAEstablished = false, numericalComparisonPerformed = false, servingEnabled = false
    let physicalProcessOrLeaseRetirementEstablished = false
}

enum Gemma4RemoteMTPTargetRuntime {
    static func execute(_ input: Gemma4RemoteMTPInput, deadline: UInt64, group: Collective,
        control: Gemma4RemoteMTPCohortControl, lifetime: Gemma4RemoteMTPNativeLifetime,
        sidecars: Gemma4BenchmarkSidecars, guardMetrics: Gemma4BenchmarkGuardMetrics,
        check: (Gemma4BenchmarkGuardObservation?) throws -> Void) throws -> Data {
        let benchmark = input.benchmark
        let owner = try Gemma4BenchmarkResourceOwner(plan:benchmark.plan,target:.fullReference,
            requests:benchmark.requests,residualDType:benchmark.job.dtype,captureEvidence:input.local.job.captureEvidence,
            prefillPolicy:.serial,deadline:deadline,guardMetrics:guardMetrics)
        let budget = try Gemma4MTPRemoteTargetBudget(requestSHA256:owner.budget.requestSHA256,
            maximumFrontier:benchmark.requests[0].finalCommittedTokens,bound:QwenResidentResourceEnvironment.allocationBound)
        let extra = try Gemma4MTPRemoteTargetResources(budget:budget,deadline:deadline)
        try owner.attachRemoteMTPResources(extra)
        func checked() throws {
            try guardMetrics.measure(.logicalGuard) {
                let observation = Gemma4BenchmarkGuardObservation(mode:.combined,deadline:deadline)
                defer { observation.close() }
                try check(observation); try owner.check(observation:observation)
                try check(observation); try observation.finish(deadline:deadline)
            }
        }
        weak var releasedModel: Module?
        let result: (Gemma4ForwardLoadReceipt,[Gemma4RemoteMTPSample]) = try autoreleasepool {
            let source = try Gemma4RegisteredSource.prepare(directory:URL(fileURLWithPath:benchmark.job.modelDirectory,isDirectory:true),
                artifact:benchmark.artifact,cut:benchmark.job.cut,check:checked)
            let embedding = try Gemma4PreparedDraftEmbedding(source:source)
            guard embedding.identitySHA256 == input.job.embeddingIdentitySHA256 else { throw ProbeError("Remote MTP actual target embedding identity differs") }
            try owner.construction(source.selection(.fullReference)); try checked()
            let prepared = try Gemma4PreparedForwardModel.prepare(source:source,target:.fullReference,check:checked)
            lifetime.model = prepared.model.module; releasedModel = prepared.model.module
            try owner.prepared(prepared)
            let loaded = try materializeRegisteredGemma4(prepared,beforeTensor:owner.beforeTensor,afterTensor:owner.afterTensor,check:checked)
            try owner.loaded(loaded.receipt); try checked()
            let probe = try loaded.probe(incomingDType:nil,incoming:nil,observeIngress:nil,check:checked)
            try owner.probeCompleted(); try checked()
            try control.checkpoint("loaded",ordinal:-1,check:checked)
            var samples: [Gemma4RemoteMTPSample] = []
            for ordinal in benchmark.requests.indices {
                let request = try input.local.iteration(ordinal)
                try owner.beginRequest(request.request)
                weak var releasedSession: Gemma4OwnedForwardSession?
                let sample = try autoreleasepool {
                    let session = try Gemma4OwnedForwardSession(loaded:loaded,request:request.request,probe:probe,
                        residualDType:benchmark.job.dtype,admitGeometry:owner.request,check:checked)
                    releasedSession = session; lifetime.session = session
                    let result = try Gemma4RemoteMTPDriver.execute(input:input,ordinal:ordinal,session:session,group:group,
                        resources:extra,lifetime:lifetime,sidecars:sidecars,check:checked)
                    try owner.retiredRequest(session)
                    try Gemma4MTPPullNativeFence.join(check:checked)
                    lifetime.session = nil
                    return result
                }
                try Gemma4MTPPullNativeFence.join(check:checked)
                guard releasedSession == nil, lifetime.target == nil else { throw ProbeError("Remote MTP target request roots escaped retirement") }
                try control.checkpoint("request-retired",ordinal:ordinal,check:checked)
                samples.append(sample)
            }
            guard samples.count == 4, Set(samples.map(\.selectedTokenIDsSHA256)).count == 1 else {
                throw ProbeError("Fresh remote MTP target requests did not reproduce identical tokens")
            }
            return (loaded.receipt,samples)
        }
        // The local stack/model references have ended; keep the explicit holder
        // until a successful fence, then prove no native model escaped its scope.
        try Gemma4MTPPullNativeFence.join(check:checked)
        lifetime.model = nil
        try Gemma4MTPPullNativeFence.join(check:checked)
        guard releasedModel == nil else { throw ProbeError("Remote MTP target model remains retained") }
        Memory.clearCache(); try checked()
        try control.checkpoint("models-released",ordinal:-1,check:checked)
        let extraReceipt = try extra.receipt(), receipt = try owner.completed()
        return try canonicalJSONData(Gemma4RemoteMTPTargetReport(configuration:input.job,ordinaryJob:benchmark.job,
            scopeSHA256:input.scopeSHA256,sourceLoad:result.0,samples:result.1,resources:receipt,
            remoteResources:extraReceipt,files:sidecars.files))
    }
}
