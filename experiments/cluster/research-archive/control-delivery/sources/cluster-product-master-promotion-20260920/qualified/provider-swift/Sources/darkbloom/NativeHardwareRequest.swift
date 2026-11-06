#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import ProviderCore
import MLXLMCommon

// Two token scalars and one terminal only. Callback performs no file IO,
// detokenization, tensor operation, extra forward or asynchronous enqueue.
final class NativeHardwareEvents: @unchecked Sendable {
    private let lock=NSLock()
    private var tokens:[Int]=[]
    private var finished=false,invalid=false
    func accept(_ event:DistributedResidentEvent)->Bool {
        lock.lock();defer{lock.unlock()}
        guard !finished,!invalid else{invalid=true;return false}
        switch event {
        case .token(let token):
            guard tokens.count<2,(0..<248_320).contains(token) else{invalid=true;return false}
            tokens.append(token);return true
        case .finished(let reason):
            finished=true
            guard reason == .length else{invalid=true;return false}
            return true
        }
    }
    func result()throws->[Int] {
        lock.lock();defer{lock.unlock()}
        guard finished,!invalid,tokens==NativeHardwareInput.expected else{throw NativeHardwareError.incomplete}
        return tokens
    }
}

extension Start {
    func executeNativeHardwareRequest(loop:ProviderLoop,input:NativeHardwareInput,pin:String) async throws {
        // Wait for a real coordinator prepare; do not repeatedly claim an
        // owner or turn a failed session into another attempt. The original
        // member request/prepare/lifetime limits remain authoritative.
        let ownerDeadline=DispatchTime.now().uptimeNanoseconds+120_000_000_000
        while await loop.nativePairMemberStatus == "idle" {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds<ownerDeadline else{throw NativeHardwareError.deadline}
            try await Task.sleep(for:.milliseconds(20))
        }
        let profile=try DistributedResidentExecutionProfile(id:"registered_qwen35_9b_greedy_generation_v1",
            vocabularySize:248_320,maxPromptTokens:8192,maxOutputTokens:128,maxContextTokens:8320,requestTimeout:.seconds(120))
        let owner=try await loop.nativePairRequestOwner(profile:profile,deadlineUptimeNanoseconds:ownerDeadline)
        var lease:(any DistributedResidentRequestLease)?
        var released=false
        do {
            guard let ready=owner.readiness(),ready.profileID==profile.id,ready.requestCapacityBytes>0,
                  ready.identity.modelID=="registered_qwen35_9b",
                  ready.identity.artifactSHA256=="127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
                  ready.identity.configurationSHA256==input.configurationSHA256,
                  ready.identity.peers.map(\.id)==input.nativePeerIDs,
                  ready.identity.peers.map(\.buildSHA256)==[input.nativeSHA256,input.nativeSHA256] else{throw NativeHardwareError.binding}
            let request=CBv2Request(id:CBv2RequestID(1),promptTokens:NativeHardwareInput.tokens,
                sampling:.init(temperature:0),maxTokens:2,prefixCacheEnabled:false)
            let value=try owner.reserve(request,identity:ready.identity,profileID:profile.id,capacityLimit:ready.requestCapacityBytes,
                deadlineContext:.init(generationDeadline:ContinuousClock.now.advanced(by:.seconds(120))))
            lease=value
            guard let provenance=value as? any DistributedResidentRequestProvenance,
                  value.requestID==request.id,value.identity==ready.identity,value.reservedBytes>0,
                  value.reservedBytes<=ready.requestCapacityBytes else{throw NativeHardwareError.binding}
            let nativeID=provenance.nativeRequestID.uuidString.lowercased()
            let common:[String:Any]=[
                "schema":"native_shared_hardware_leader_result_v1","configurationFileSHA256":pin,
                "publicRequestID":NativeHardwareInput.publicID.uuidString.lowercased(),"cbv2RequestID":request.id.raw,
                "nativeRequestID":nativeID,"membershipEpoch":ready.identity.membershipEpoch.uuidString.lowercased(),
                "tlsConfigurationSHA256":input.tlsConfigurationSHA256,
                "nativeSHA256":input.nativeSHA256,"cliSHA256":input.cliSHA256,"descriptorSHA256":input.descriptorSHA256,
                "capabilitySHA256":input.capabilitySHA256,"resourcePolicySHA256":input.resourcePolicySHA256,
                "planSHA256":input.planSHA256,"configurationSHA256":ready.identity.configurationSHA256,
                "nativePeerIDs":ready.identity.peers.map(\.id),
                "inputBindingSHA256":input.inputBindingSHA256,"requestSHA256":input.requestSHA256,"referenceSHA256":input.referenceSHA256,
                "reservedBytes":value.reservedBytes,"readyCapacityBytes":ready.requestCapacityBytes,
                "numericallyQualified":false,"hardwareSmokeOnly":true]
            try input.publish("reserved.json",common) // before request start, outside inference
            let events=NativeHardwareEvents()
            try await withTaskCancellationHandler {
                try value.start {events.accept($0)}
                await value.waitUntilRetired()
            } onCancel: {value.cancel()}
            value.releaseResources();released=true
            let bytesAfter=value.bytesInUse
            // Retained remote-view cleanup completes ONLY upon the original
            // authenticated all-owner release. A timer/EOF cannot complete it.
            await owner.shutdown()
            let tokens=try events.result()
            guard bytesAfter==0 else{throw NativeHardwareError.incomplete}
            var result=common
            result["tokenIDs"]=tokens;result["requestRetired"]=true;result["bytesInUseAfterRelease"]=bytesAfter
            result["retainedOwnerShutdownReturned"]=true
            result["success"]=true
            try input.publish("leader-result.json",result)
        } catch {
            if let lease,!released {lease.cancel();await lease.waitUntilRetired();lease.releaseResources()}
            await owner.shutdown()
            throw error
        }
    }
}
#endif
