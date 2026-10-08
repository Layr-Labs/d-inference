import Foundation
import CryptoKit
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite("Retained protected member requests")
struct NativePairSharedRequestTests {
    @Test func workerPacketHasIndependentCanonicalBytes() throws {
        let digest=Data(repeating:0x7f,count:32)
        let p=try NativePairWorkerPacket(kind:.command,transcript:digest,deliverySlack:1,generationSlack:2,payload:Data("abc".utf8))
        let hex=p.bytes.map{String(format:"%02x",$0)}.joined()
        #expect(hex=="44424e570102"+String(repeating:"7f",count:32)+"0000000000000001000000000000000200000003616263")
        let decoded=try NativePairWorkerPacket(p.bytes,type:"native_pair_worker_command",transcript:digest)
        #expect(decoded.deliverySlack==1 && decoded.generationSlack==2 && decoded.payload==Data("abc".utf8))
    }
    @Test func workerPacketRejectsDirectionContextTruncationAndLimits() throws {
        let d=Data(repeating:1,count:32),p=try NativePairWorkerPacket(kind:.ready,transcript:d,payload:Data([1]))
        for length in [0,5,38,58,p.bytes.count-1] {
            #expect(throws:(any Error).self){try NativePairWorkerPacket(Data(p.bytes.prefix(length)),type:"native_pair_worker_ready",transcript:d)}
        }
        #expect(throws:(any Error).self){try NativePairWorkerPacket(p.bytes,type:"native_pair_worker_event",transcript:d)}
        #expect(throws:(any Error).self){try NativePairWorkerPacket(p.bytes,type:"native_pair_worker_ready",transcript:Data(repeating:2,count:32))}
        #expect(throws:(any Error).self){try NativePairWorkerPacket(kind:.event,transcript:d,deliverySlack:1,payload:Data([1]))}
        #expect(throws:(any Error).self){try NativePairWorkerPacket(kind:.event,transcript:d,payload:Data(repeating:1,count:16385))}
    }
    @Test func requestDeadlinesUseOriginalLifetimeSlackWithoutTransitRestart() throws {
        let now=DispatchTime.now().uptimeNanoseconds,lifetime=now+5_000_000_000,generation=now+3_000_000_000,delivery=now+1_000_000_000
        let r=ClusterWorkerReservation(profileID:"registered_qwen35_9b_greedy_generation_v1",promptTokenIDs:Array(repeating:1,count:32),
            stopTokenIDs:[],outputCount:2,chunkSize:16,deadlineUptimeNanoseconds:generation,capacityLimitBytes:500_000_000)
        let p=try NativePairWorkerPacket.command(.init(membershipEpoch:UUID(),sequence:0,requestID:UUID(),command:.reserve(r)),
            transcript:Data(repeating:1,count:32),lifetime:lifetime,deliveryDeadline:delivery)
        let (translated,end)=try p.localCommand(lifetime:lifetime,now:now+500_000_000)
        #expect(end==delivery)
        guard case .reserve(let value)=translated.command else {Issue.record("reserve lost");return}
        #expect(value.deadlineUptimeNanoseconds==generation)
        #expect(throws:(any Error).self){try p.localCommand(lifetime:lifetime,now:delivery)}
        let otherClock:UInt64=100_000_000_000
        let (other,otherEnd)=try p.localCommand(lifetime:otherClock,now:otherClock-5_000_000_000)
        #expect(otherEnd==otherClock-4_000_000_000)
        guard case .reserve(let converted)=other.command else {Issue.record("reserve lost");return}
        #expect(converted.deadlineUptimeNanoseconds==otherClock-2_000_000_000)
    }
    @Test func requestAdapterKeepsExactNativeWorkload() throws {
        func value(prompt:Int=32,output:Int=2,chunk:Int=16,stops:[Int]=[])->ClusterWorkerReservation {
            .init(profileID:"registered_qwen35_9b_greedy_generation_v1",promptTokenIDs:Array(repeating:1,count:prompt),stopTokenIDs:stops,
                outputCount:output,chunkSize:chunk,deadlineUptimeNanoseconds:1,capacityLimitBytes:1)
        }
        try NativePairWorkerPacket.requireExperiment(value())
        for bad in [value(prompt:31),value(output:1),value(chunk:32),value(stops:[2])] {
            #expect(throws:(any Error).self){try NativePairWorkerPacket.requireExperiment(bad)}
        }
    }
    @Test func protectedReadyRequiresExactBindingAndActualChargedCapacity() throws {
        let f=try Fixture()
        try f.gate.validate(f.ready())
        #expect(throws:(any Error).self){try f.gate.validate(f.ready(capacity:186_302_720))}
        #expect(throws:(any Error).self){try f.gate.validate(f.ready(rank:1))}
        var changed=f.description;changed.append(32)
        #expect(throws:(any Error).self){try ClusterOwnerProtectedReady(verifiedDescription:changed,
            expectedDescriptionSHA256:f.descriptionHash,start:f.start,identity:f.identity,profile:f.profile)}
    }
    @Test func retainedViewPreservesSequenceAndNeverInfersCleanup() throws {
        let f=try Fixture(),end=DispatchTime.now().uptimeNanoseconds+1_000_000_000
        let view=NativePairRetainedEndpoint(identity:f.identity,profile:f.profile,rank:0,plan:f.plan,lifetime:end,
            readyPolicy:f.gate,send:{_,_,_ in},cancel:{})
        let ready=ClusterWorkerEventFrame(membershipEpoch:f.identity.membershipEpoch,sequence:0,requestID:nil,event:.ready(f.ready()))
        try view.accept(ready)
        #expect(try view.receiveWorkerEvent(until:end,cancelled:{false})==ready)
        #expect(throws:(any Error).self){try view.accept(ready)}
        let terminal=ClusterWorkerEventFrame(membershipEpoch:f.identity.membershipEpoch,sequence:1,requestID:UUID(),event:.finished(.length))
        try view.accept(terminal)
        #expect(!view.nativeCleanupObserved)
        view.invalidate()
        #expect(view.readiness==nil && !view.nativeCleanupObserved)
        // Cancellation must suppress an already-queued success even before the
        // Pair's asynchronous invalidation observer has run.
        #expect(throws:(any Error).self){try view.receiveWorkerEvent(until:end,cancelled:{false})}
        view.observeCleanup()
        #expect(view.nativeCleanupObserved)
        #expect(throws:(any Error).self){try view.receiveWorkerEvent(until:end,cancelled:{false})}
        let clean=NativePairRetainedEndpoint(identity:f.identity,profile:f.profile,rank:0,plan:f.plan,lifetime:end,
            readyPolicy:f.gate,send:{_,_,_ in},cancel:{})
        try clean.accept(ready)
        _ = try clean.receiveWorkerEvent(until:end,cancelled:{false})
        try clean.accept(terminal)
        clean.observeCleanup()
        #expect(clean.readiness==nil && clean.nativeCleanupObserved)
        #expect(try clean.receiveWorkerEvent(until:end,cancelled:{false})==terminal)
        #expect(throws:(any Error).self){try clean.sendWorkerCommand(.shutdown,requestID:nil,deadline:end)}
    }
    private struct Fixture {
        let start:ClusterNativeAuthorizationStart,identity:ClusterWorkerIdentity,profile:ClusterWorkerProfile
        let description:Data,descriptionHash:String,plan:String,gate:ClusterOwnerProtectedReady
        init() throws {
            func d(_ n:UInt8)->Data{Data(repeating:n,count:32)}
            func h(_ b:Data)->String{b.map{String(format:"%02x",$0)}.joined()}
            let resource=Data(base64Encoded:"eyJhZGRpdGlvbmFsSG9zdEJ5dGVzIjoxNTI3NDgyODgsImFkZGl0aW9uYWxOYXRpdmVCeXRlcyI6MzM1NTQ0MzIsImFsbG9jYXRpb25OYXRpdmVTSEEyNTYiOiI0ZjQxNDljNzMzMGQ4MjY4YWM3Mjk0ZWY3YjIyNWRiMjUwNzhkMmZiODUzY2IwNmFmMWQwMmU3M2FlNjZiMjZjIiwiYWxsb2NhdGlvblJldmlld3MiOlsiMTRlOTcwYjA2ZmMwM2RmZmY5NDFjNjhkNjk5OGJjOTJmZmFjMWIyNDc4ZjMyYWVhODY5YTJmY2ZjM2UyOTFmZSIsIjczYmU3N2YxZjdkZDAwMjk1NDc2ZmU3ZjI3NjY1NWFiMjg1Y2I0ODUyNDBhODQ3OWFiMWEyNzVmYTM2NTU5ZDAiXSwiYWxsb2NhdG9ySGVhZHJvb21CeXRlcyI6MjE0NzQ4MzY0OCwiYWxsb2NhdG9yUG9saWN5IjoiZGlzYWJsZV9mcmVlZF9idWZmZXJfY2FjaGVfdjEiLCJoYXJkd2FyZU1vZGVsIjoiTWFjMTYsNyIsImtleUFuZE1ldGFkYXRhQWxsb3dhbmNlQnl0ZXMiOjEwNDg1NzYsImxvYWRpbmdIZWFkcm9vbUJ5dGVzIjo0Mjk0OTY3Mjk2LCJsb2dpY2FsSG9zdENvcGllcyI6NTI0NDQ4LCJtYXhpbXVtQ3VtdWxhdGl2ZVBsYWludGV4dEJ5dGVzUGVyRGlyZWN0aW9uIjoxNjc3NzIxNiwibWF4aW11bUZyYW1lQnl0ZXMiOjEzMTExMiwibWF4aW11bUluRmxpZ2h0T3BlcmF0aW9ucyI6MSwibWF4aW11bVBsYWludGV4dEJ5dGVzIjoxMzEwNzIsIm1heGltdW1SZWNvcmRzUGVyRGlyZWN0aW9uIjoxMDI0LCJtZXNoQmFja2luZ0J5dGVzIjoxMjUzMzc2MCwibWluaW11bUFjdHVhbEZyZWVCeXRlcyI6NjQ0MjQ1MDk0NCwib2JzZXJ2ZWROYXRpdmVJbmNyZW1lbnRCeXRlcyI6MjA5ODc5MDQsIm9ic2VydmVkUGh5c2ljYWxJbmNyZW1lbnRCeXRlcyI6NzE1MzI2NDAsIm9wZXJhdGlvbmFsU2FmZXR5Qnl0ZXMiOjY3MTA4ODY0LCJvc0J1aWxkIjoiMjZBNDI4IiwicGh5c2ljYWxNZW1vcnlCeXRlcyI6WzI1NzY5ODAzNzc2LDUxNTM5NjA3NTUyXSwicHJvZmlsZSI6InF3ZW45Yl9zaG9ydF9yZWNvcmRzX2V4cGVyaW1lbnRfdjEiLCJyZG1hTWVhc3VyZWQiOmZhbHNlLCJzY2hlbWEiOiJxd2VuOWJfcHJvdGVjdGVkX29wZXJhdGlvbmFsX3Jlc291cmNlc192MSIsInNlcGFyYXRlRGlyZWN0aW9uQ29kZWNzIjpmYWxzZSwic2VydmluZ0VuYWJsZWQiOmZhbHNlLCJzb3VyY2VCaW5kaW5ncyI6eyJhbGxvY2F0aW9uUHJvYmUiOiJkMDI0ZGZjMTQ4NDQ5MjZiZDhlZTE0NjIwODI2Y2M5YjBhZTQyOWZkOGE0NmUwOTdkN2E0MmZlZWRlODU2OThlIiwiamFjY2wvbWVzaC5jcHAiOiI5Y2VlYjk0YTUwNzExM2JlOTIwNjI1NWVmZmYxYmIwOWQ5ZDU5OGU0NGVhYmVkMzQwYzA4MDhlMjZjZTBjZjIyIiwiamFjY2wvbWVzaF9pbXBsLmgiOiIzZWEwN2RmNjdhYWUzZDAzMjdmMTExZGUzYjc2NzNjOGM3NmE2YzIzNjI2ODJkNGIwODVjZDEwYThkNTg0N2Y1IiwiamFjY2wvcmRtYS5oIjoiNzI2Zjk0Yjk2ZmViZDJlYzI5NDI2OTg3MmQ2NjcyYmNhZjBhNGZjOTdlY2JlZjk0NzRiZGY5N2I0ZTk2MjQ5OCIsImphY2NsL3JpbmdfaW1wbC5oIjoiMWY3MWIyNmE4NDQ4ZjZlZjQ2YWFmZGFlMGQzZmY3NjBiNzIzMTdjZDMyNzZhMDY5YjdkNmI5MjAyNGViMmEzMyIsImphY2NsL3NlbmRfZnJhbWUuaCI6Ijc3MTg0NmFlMDQwNmJjMjIwM2IzN2VjOTYyMGIzMTU4NDA1NDMzZmJlNzY0MjFlMzE1Mjk2NjcwYzNjNTkwYzciLCJuYXRpdmVQcmVsdWRlIjoiNjFmMjg4ODdlNjE2NWM2ZjQ4ODA3MTg4Mjg2ODIxNmM2ZTkyYmIxZjFmNmY4MWNlYzgyNmM3ZGUwMzQ5YzViZiIsInByb3RlY3RlZFNjb3BlcyI6IjQzMzhjZTViZTI1ZDk1YzdlYzY4Zjg3YWIyZmNkNTExMjJjZWVlODA1OGRlNjM2NDYzZjU4OTFmZTRmZWUxMDciLCJzZWN1cml0eS9DbHVzdGVyQXV0aGVudGljYXRlZFJlY29yZENoYW5uZWwuc3dpZnQiOiI2ZDgxNjI4ZTU3ODA2MTJjYmVkZGU3MWI4MmU1YzVlM2ZkNTNlZjMwY2MzODEwZWE5N2U5NzRhNzg4ZmVhZDlkIiwic2VjdXJpdHkvQ2x1c3RlckF1dGhlbnRpY2F0ZWRSZWNvcmRUcmFuc3BvcnQuc3dpZnQiOiI2ZjIwZTYwNWYxZDAxMTZmMTkyOTA3ZjM5NjZlM2FlZWIxYzIzNGU2NDkxMjc5YTFiZTdhMzJhMmViMGIyM2NhIiwic2VjdXJpdHkvQ2x1c3RlclJlY29yZEJ5dGVJTy5zd2lmdCI6ImQ4YTgyMzA1MWRkNjljYzEzYTFiZDZjZDZmNjkzNjNhNGEyZmNjYzVjYzM2ZGNiZDY0YjI2MjUwOWNlMjFkMTkiLCJzZWN1cml0eS9DbHVzdGVyUmVjb3JkRnJhbWluZy5zd2lmdCI6IjFiZWQ3NmE2MDE2Y2MxOGVmNGEzNWI0NWMyYWYzMDViZmU1Y2UxMzQyYzkyNWQ5ZTc0YmQ2YmNkYTU1ZWZmY2UiLCJzZWN1cml0eS9DbHVzdGVyUmVjb3JkU3RhdGUuc3dpZnQiOiI5MTU3N2E5Y2YyYjlhN2QyNzQ4NDZlMTMyNzQ3NjQ4MjVlM2NiMWRlMTQ1OWQ4Njk5NTViMWQyMTAyN2IxZTYxIiwic2VjdXJpdHkvQ2x1c3RlclJlY29yZFRyYW5zZmVyQWNjb3VudGluZy5zd2lmdCI6ImFhYjAzNmM5OTkxZjM1ZTQwZjJhN2Q4YTAyODNjOGZjNTRjNzNmNDBiM2UzNmY1MmExNTE1ZjZiNWUzNjMzOWQiLCJzZWN1cml0eS9DbHVzdGVyUmVjb3JkVHJhbnNmZXJFeHBlY3RhdGlvbi5zd2lmdCI6IjE1MWY2NzM5OTNiMzM5MWQ0ZmQwYmE5MzdjMDRkMmQ2NTMxZmIyM2JkMjQ4ZjQ2YTViNjA4Zjk3ZGRjOTZhNTciLCJzZWN1cml0eS9DbHVzdGVyUmVjb3JkVHlwZXMuc3dpZnQiOiI3MjNlMWU2M2Q5YjZmOGZjMGEzOGY0N2I5NDE1MmZhMDI2ZmJhNDc4ZDA1NjQyNDk0YjZhYWIwNWY2OTQwMzY2In0sInN1aXRlIjoiYWVzMjU2R2NtSGtkZlNoYTI1NlYxIiwid2hvbGVQcm9jZXNzUGVha1Byb3ZlbiI6ZmFsc2V9")!
            let resourceHash=Data(SHA256.hash(data:resource))
            let epoch=UUID(),common=try ClusterNativeAuthorizationCommon(epoch:epoch,membershipGeneration:1,nativePolicyGeneration:1,
                membershipTranscriptSHA256:d(1),approvedNativeBindingSHA256:d(2),planSHA256:d(3),artifactSHA256:d(4),nativeRuntimeSHA256:d(5),
                capabilitySHA256:d(6),resourcePolicySHA256:resourceHash,profileSHA256:d(8),schedule:.serial,maximumTransportFrameBytes:131112,
                limits:.init(maximumPlaintextBytes:131072,maximumRecordsPerDirection:1024,maximumCumulativePlaintextBytesPerDirection:16777216))
            start=try .init(common:common,rank:0,ownerIncarnation:UUID(),leaseID:UUID(),launchID:UUID())
            identity = .init(membershipEpoch:epoch,modelID:"fixture-only",artifactSHA256:h(d(4)),configurationSHA256:h(d(9)),
                peers:[.init(id:"a",buildSHA256:h(d(5))),.init(id:"b",buildSHA256:h(d(5)))])
            profile = .init(id:"registered_qwen35_9b_greedy_generation_v1",vocabularySize:248320,maximumPromptTokens:8192,
                maximumOutputTokens:128,maximumChunkTokens:512,maximumContextTokens:8320);plan=h(d(3))
            // Narrow gate fixture only. Installed attachment separately validates
            // the complete pinned descriptor/artifacts before making this value.
            description=try JSONSerialization.data(withJSONObject:["schema":"qwen9b_protected_runtime_description_v1",
                "staticProfile":"qwen9b_short_records_experiment_v1","bootstrapProfile":"native_key_prelude_mesh2_v1",
                "prefillSchedule":"serial_v1","stageCut":16,"promptTokens":32,"chunkTokens":16,"outputTokens":2,"stopTokenIDs":[Int](),
                "runtimeBinarySHA256":h(d(5)),"capabilitySHA256":h(d(6)),"selectedPlanSHA256":h(d(3)),
                "profileFingerprint":h(d(8)),"resourcePolicySHA256":h(resourceHash),"resourcePolicyBase64":resource.base64EncodedString()],options:[.sortedKeys])
            descriptionHash=h(Data(SHA256.hash(data:description)))
            gate=try .init(verifiedDescription:description,expectedDescriptionSHA256:descriptionHash,start:start,identity:identity,profile:profile)
        }
        func ready(capacity:Int=186_302_721,rank:Int=0)->ClusterWorkerReady {
            .init(identity:identity,rank:rank,profile:profile,executionPlanSHA256:plan,requestCapacityBytes:capacity)
        }
    }
}
