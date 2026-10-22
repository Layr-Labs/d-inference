import Foundation

/// Fabricated scalar/schema fixture, never returned as execution evidence.
/// Exercises the exact final encoder with all150 records,90 state entries,
/// complete named resource arrays and maximum-width nonnegative counters.
enum Gemma4ExpertEncodingChecks {
    static func run(input original: Gemma4ExpertCorrectnessInput) throws -> [String:Any] {
        let job = original.job
        let input = try Gemma4ExpertCorrectnessInput(job:.init(schema:job.schema,mode:"expert0",
            modelDirectory:job.modelDirectory,metadataDirectory:job.metadataDirectory,promptFile:job.promptFile,
            promptFileSHA256:job.promptFileSHA256,outputDirectory:job.outputDirectory,requestID:job.requestID,
            membershipEpoch:job.membershipEpoch,buildIdentitySHA256:job.rankBuildSHA256[0],
            rankBuildSHA256:job.rankBuildSHA256,globalExpertIDsByRank:job.globalExpertIDsByRank,
            timeoutSeconds:job.timeoutSeconds))
        let budget = try Gemma4ShortResourceBudget.derive(plan:input.plan,target:input.target,
            request:input.request,bound:{(($0+16_383)/16_384)*16_384})
        let hash = String(repeating:"f",count:64), maximum = Int.max
        let binding = Gemma4ShortSessionBinding(target:"expert-rank-0:"+hash,
            planSHA256:hash,artifactSHA256:hash,configurationSHA256:hash,
            parameterLayoutSHA256:hash,stateLayoutSHA256:hash,readAccountingSHA256:hash,
            selectedTensorCount:1339,selectedBytes:maximum,maximumTokens:34,maximumChunkTokens:16,
            layers:budget.stateLayers.map { .init(localIndex:$0.globalIndex,globalIndex:$0.globalIndex,
                kvHeads:$0.kvHeads,headDimension:$0.headDimension,window:$0.window ?? 0,dtype:"bfloat16") },
            probePrefillTokens:2,probeDecodeTokens:1)
        var accounting = CheckpointAlignedReadAccounting()
        try accounting.recordCall(requested:maximum,returned:maximum,interrupted:false,shortEOF:false)
        try accounting.finish(selected:maximum,scratchRequested:CheckpointAlignedReadPlan.maximumScratchRequestBytes,
            scratchAllocated:CheckpointAlignedReadPlan.maximumScratchAllocationBytes)
        let source = Gemma4ForwardLoadReceipt(artifactSHA256:hash,configurationSHA256:hash,planSHA256:hash,
            target:binding.target,parameterLayoutSHA256:hash,sourceTensorCount:1697,selectedTensorCount:1339,
            loadedTensorBytes:maximum,largestHostTensorBytes:maximum,readAccounting:accounting)
        let entries: [Gemma4ShortState.Entry] = (0..<30).flatMap { layer in
            ["kv.keys","kv.values","kv.position_offsets"].map { component in
                .init(localLayerIndex:layer,globalLayerIndex:layer,component:component,
                    dtype:"bfloat16",sha256:hash,shape:[1,32,33,512],byteCount:maximum,logicalRange:[0,33],
                    file:.init(name:"state-\(layer)-\(component).bin",bytes:maximum,sha256:hash))
            }
        }
        let rows: [Gemma4ShortRow] = (0..<2).map {
            .init(ordinal:$0,frontier:32+$0,tokenID:262143,maximumTieCount:262144,
                file:.init(name:"logits-\($0).json",bytes:maximum,sha256:hash),
                dtype:"bfloat16",logicalBytesSHA256:hash)
        }
        let execution = Gemma4ShortExecution(binding:binding,sourceLoad:source,
            selectedTokenIDs:[262143,262143],selectedTokenIDsSHA256:hash,
            frames:(0..<3).map{.init(sequence:$0,frontier:$0==0 ? 16 : 31+$0,
                tokenIDsSHA256:hash,boundarySHA256:nil)},rows:rows,
            finalState:.init(frontier:33,fingerprint:hash,entries:entries),
            files:rows.map(\.file)+entries.map(\.file))
        var observations: [Gemma4ExpertExchangeObservation] = []
        for purpose in [Gemma4ExpertInvocationBinding.Purpose.probe,.request] {
            let frames = purpose == .probe ? Gemma4ExpertExchangeSchedule.probeFrames
                : Gemma4ExpertExchangeSchedule.requestFrames
            for position in frames {
                let frame = QwenLayerStageFrame(sequence:position.sequence,
                    phase:position.phase == "prefill" ? .prefill : .decode,
                    tokenOffset:position.offset,tokenCount:position.count,finalPromptChunk:position.finalPrompt)
                let counts = [position.count*4,position.count*4]
                let policies = try (0..<2).map { rank in
                    try ExpertAxisProjectionPolicy(globalAssignments:position.count*8,globalExperts:128,
                        ownedExperts:job.globalExpertIDsByRank[rank].count,localAssignments:counts[rank])
                }
                for layer in 0..<30 {
                    observations.append(.init(scope:.init(binding:input.binding(purpose:purpose),frame:frame,
                        globalLayer:layer,tokenCount:position.count,dtype:"bfloat16",routeSHA256:hash,
                        inputSHA256:hash,weightsSHA256:hash,assignmentCounts:counts,projectionPolicies:policies),
                        scopeSHA256:hash,rank0OutputSHA256:hash,rank1OutputSHA256:hash))
                }
            }
        }
        let receipt = Gemma4ShortResourceReceipt(planSHA256:hash,requestSHA256:hash,
            selectedTensorCount:1339,completedTensorCount:1339,constructorParameterCount:1339,
            constructorUnmaterializedQuantizedParameterCount:1339,
            constructorObservedActiveBytes:maximum,constructorObservedNativePeakBytes:maximum,
            namedNativeReserveBytes:maximum,hostEvidenceReserveBytes:maximum,
            persistentCastLogicalBytes:maximum,stateLogicalBytes:maximum,expertResources:budget.expertResources,
            selectedAllocationBounds:budget.selectedBounds,namedArrays:budget.namedArrays,
            namedAllocationBounds:budget.namedAllocationBounds,observationCount:maximum,
            minimumActualFreeBytes:maximum,maximumObservedActiveBytes:maximum,maximumObservedNativePeakBytes:maximum)
        let dictionary = try QwenLayerStageGenerationWireJSON.object(canonicalJSONData(execution),
            maximumBytes:Gemma4ExpertCorrectnessReport.limit)
        let intermediate = try Gemma4ExpertCorrectnessReport.intermediate(input:input,
            expected:input.description(),execution:dictionary,observations:observations,
            sentTensorBytes:maximum,receivedTensorBytes:maximum,
            controlRecordsSent:607,controlRecordsReceived:607)
        let final = try Gemma4ExpertCorrectnessReport.finish(intermediate,resources:receipt,
            collectiveCreated:true,cacheBytes:0)
        guard observations.count == 150, entries.count == 90, final.count <= Gemma4ExpertCorrectnessReport.limit else {
            throw ProbeError("Gemma EP exact report encoder fixture differs")
        }
        var refused = false
        do {
            var oversized = dictionary
            oversized["fixturePadding"] = String(repeating:"x",count:Gemma4ExpertCorrectnessReport.limit)
            _ = try Gemma4ExpertCorrectnessReport.intermediate(input:input,expected:input.description(),
                execution:oversized,observations:observations,sentTensorBytes:0,receivedTensorBytes:0,
                controlRecordsSent:607,controlRecordsReceived:607)
        } catch { refused = true }
        guard refused else { throw ProbeError("Gemma EP encoder accepted oversized fixture") }
        return ["fabricatedSchemaFixtureOnly":true,"maximumWidthEncodingBytes":final.count,
            "limit":Gemma4ExpertCorrectnessReport.limit,"exchangeRecords":observations.count,
            "stateEntries":entries.count,"oversizedRefused":refused]
    }
}
