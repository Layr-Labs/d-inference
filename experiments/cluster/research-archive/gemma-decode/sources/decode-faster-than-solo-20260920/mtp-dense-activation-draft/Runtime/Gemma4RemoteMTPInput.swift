import Foundation

struct Gemma4RemoteMTPJob: Codable {
    let schema: String, role: String
    let localMTPJob: String, localMTPJobSHA256: String
    let targetNativeSHA256: String, assistantNativeSHA256: String, embeddingIdentitySHA256: String
    var rank: Int { role == "target" ? 1 : 0 }
    func validate() throws {
        guard schema == "gemma4_remote_mtp_cohort_job_v1", ["target","assistant"].contains(role),
              [localMTPJobSHA256,targetNativeSHA256,assistantNativeSHA256,embeddingIdentitySHA256].allSatisfy(qwenStageWireIsSHA256),
              localMTPJob.hasPrefix("/"), localMTPJob.utf8.count <= 2048, !localMTPJob.contains("\0"),
              URL(fileURLWithPath:localMTPJob).standardizedFileURL.path == localMTPJob else {
            throw ProbeError("Remote MTP explicit role/job/native identity differs")
        }
    }
}

/// Reuses the closed local P128/P4096 C64 O16 metadata and registered artifacts.
/// Ordinary/local capability is untouched; this explicit wrapper owns topology.
struct Gemma4RemoteMTPInput {
    let job: Gemma4RemoteMTPJob
    let local: Gemma4LocalMTPInput
    let scopeSHA256: String
    let denseProjectionEnabled: Bool
    var benchmark: Gemma4BenchmarkInput { local.benchmark }
    init(url: URL, denseProjectionEnabled: Bool = false) throws {
        let bytes = try BoundedProbeInput.data(url,maximumBytes:16_384)
        try validateWorkerJSON(bytes)
        let job = try JSONDecoder().decode(Gemma4RemoteMTPJob.self,from:bytes)
        try job.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes),job)
        let localBytes = try BoundedProbeInput.data(URL(fileURLWithPath:job.localMTPJob),maximumBytes:16_384)
        guard sha256(localBytes) == job.localMTPJobSHA256 else { throw ProbeError("Remote MTP local metadata changed") }
        let local = try Gemma4LocalMTPInput(url:URL(fileURLWithPath:job.localMTPJob),qualifyConditioning:false,
            denseProjectionEnabled:denseProjectionEnabled)
        guard local.job.maximumDraftTokens == 2,
              local.benchmark.job.buildIdentitySHA256 == (job.rank == 1 ? job.targetNativeSHA256 : job.assistantNativeSHA256) else {
            throw ProbeError("Remote MTP needs depth2 and the actual local native identity")
        }
        self.job = job; self.local = local; self.denseProjectionEnabled = denseProjectionEnabled
        // Local paths/role are intentionally excluded from the bilateral scope.
        // Both exact local input files remain independently bound by parent jobs.
        scopeSHA256 = sha256(Data((["gemma4_remote_mtp_cohort_v1",local.benchmark.job.membershipEpoch,
            job.targetNativeSHA256,job.assistantNativeSHA256,job.embeddingIdentitySHA256,
            Gemma4ArtifactMetadata.artifactAggregateSHA256,Gemma4AssistantArtifact.aggregateSHA256,
            local.benchmark.plan.fingerprint,local.benchmark.job.promptFileSHA256,
            "depth=2","buffer=5","targetRank=1","assistantRank=0",
            "capture=\(local.job.captureEvidence)"]+local.benchmark.requests.map(\.fingerprint)
            + (denseProjectionEnabled ? ["targetProjection="+Gemma4MTPDenseProjection.policy] : [])).joined(separator:"\n").utf8))
    }
    func requestScope(_ ordinal: Int) throws -> AsyncMTPProposalLedger.Scope {
        guard benchmark.requests.indices.contains(ordinal), let epoch = UUID(uuidString:benchmark.job.membershipEpoch) else {
            throw ProbeError("Remote MTP request ordinal or epoch differs")
        }
        return .init(requestID:benchmark.requests[ordinal].requestID,membershipEpoch:epoch,
            targetBuildSHA256:job.targetNativeSHA256,assistantBuildSHA256:job.assistantNativeSHA256,
            targetArtifactSHA256:Gemma4ArtifactMetadata.artifactAggregateSHA256,
            assistantArtifactSHA256:Gemma4AssistantArtifact.aggregateSHA256,
            embeddingIdentitySHA256:job.embeddingIdentitySHA256)
    }
    /// The additive resident resource ledger uses the first request fingerprint;
    /// all four requests have identical workload. The current UUID is separately
    /// bound by Scope, and both endpoints admit the exact four-request input.
    var resourceRequestSHA256: String { benchmark.requests[0].fingerprint }
    func wireScope(_ ordinal: Int) throws -> String {
        let scope = try requestScope(ordinal)
        let request = benchmark.requests[ordinal]
        return Gemma4MTPPullRecord.scopeFingerprint(scope,requestSHA256:resourceRequestSHA256,
            initialFrontier:request.promptCount+1,maximumInputFrontier:request.finalCommittedTokens)
    }
    func description() throws -> Data {
        let target = try Gemma4MTPRemoteTargetBudget(requestSHA256:resourceRequestSHA256,
            maximumFrontier:benchmark.requests[0].finalCommittedTokens,serialTargetHead:denseProjectionEnabled,bound:{$0})
        let assistant = try Gemma4MTPAuxiliaryBudget(artifact:local.assistant,placement:.remoteAssistant,
            requestSHA256:resourceRequestSHA256,maximumFrontier:benchmark.requests[0].finalCommittedTokens,bound:{$0})
        var report: [String: Any] = [
            "schema":"gemma4_remote_mtp_cohort_capability_v1","job":try JSONSerialization.jsonObject(with:canonicalJSONData(job)),
            "scopeSHA256":scopeSHA256,"role":job.role,"rank":job.rank,"maximumDraftTokens":2,"maximumBufferedProposals":5,
            "requestSHA256s":benchmark.requests.map(\.fingerprint),"targetExtraLogicalNativeBytes":target.nativeBytes,
            "targetExtraHostBytes":target.hostBytes,"assistantLogicalNativeBytes":assistant.liveNativeBytes,
            "assistantHostBytes":assistant.liveHostBytes,"assistantConstructorBytes":assistant.constructorBytes,
            "metadataOnly":true,"actualAllocatorBoundsApplied":false,"mtpEnabled":true,"remoteAssistant":true,
            "servingEnabled":false,"runtimeExecutionAuthorized":false,"numericalComparisonPerformed":false,
            "physicalRetirementEstablished":false]
        if denseProjectionEnabled { report["targetProjectionPolicy"] = Gemma4MTPDenseProjection.policy }
        return try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.withoutEscapingSlashes])
    }
}
