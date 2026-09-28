import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
import MLXLMCommon
@testable import InstalledContract

struct CheckFailure: Error { let message:String }
func require(_ value:Bool,_ message:String) throws { if !value { throw CheckFailure(message:message) } }
func rejected(_ body:() throws->Void) throws {
    do { try body() } catch is CheckFailure { throw CheckFailure(message:"assertion inside refusal") } catch { return }
    throw CheckFailure(message:"expected refusal")
}
final class EndpointBox: @unchecked Sendable {
    let lock=NSLock(); var values:[ClusterRemoteWorkerEndpoint]=[]
    func add(_ value:ClusterRemoteWorkerEndpoint){ lock.withLock { values.append(value) } }
    var snapshot:[ClusterRemoteWorkerEndpoint]{ lock.withLock { values } }
}

@main enum InstalledSessionCheck {
    static func main() async throws {
        signal(SIGALRM){_ in Darwin._exit(124)};alarm(50);defer{alarm(0)}
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("installed-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let fixture=try InstalledFixture.make(root:root,probe:URL(fileURLWithPath:CommandLine.arguments[1]),
            owner:URL(fileURLWithPath:CommandLine.arguments[2]),worker:URL(fileURLWithPath:CommandLine.arguments[3]))
        let prepared=try fixture.prepare()
        try require(prepared.manifest.modelID==fixture.configuration.publicModelID && prepared.model.eosTokenIDs==[7],"public/native metadata join failed")
        try require(prepared.model.modelType=="qwen3_5" && prepared.model.directory.lastPathComponent=="model","model discovery metadata differs")
        try require(!FileManager.default.fileExists(atPath:prepared.model.directory.appendingPathComponent("model.safetensors").path),"fixture unexpectedly has payload")
        try require(try prepared.model.stopTokenIDs(tokenizerEOS:9)==[7,9],"loaded tokenizer EOS union differs")
        try rejected{_ = try prepared.model.stopTokenIDs(tokenizerEOS:248320)}
        try metadataChecks(fixture,prepared)
        try fileAndProbeChecks(fixture,prepared)
        try await normalAndDrain(fixture,prepared)
        try await exhausted(fixture,prepared)
        try await failedStart(fixture,prepared)
        try await missingRelease(fixture,prepared)
        try await expired(fixture)
        print("Installed owner/session: metadata, bounded IO and 6 lifecycle scenarios passed; no native model, SSH or network")
    }
    static func changedConfiguration(_ f:InstalledFixture,edit:(inout [String:Any])->Void) throws->ClusterConfiguration {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.configuration)) as! [String:Any];edit(&object)
        return try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:object),capability:f.capability,capabilitySHA256:f.configuration.capabilitySHA256)
    }
    static func metadataChecks(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        for change in [0,1,2] {
            let c=try changedConfiguration(f){ object in
                if change==0 { object["publicModelID"]="unrelated/public-model" }
                else { var files=object["tokenizerFiles"] as! [[String:Any]]
                    if change==1 { files.removeLast() } else { files[0]["sha256"]=String(repeating:"0",count:64) };object["tokenizerFiles"]=files }
            }
            try rejected{_ = try DistributedInstalledManifest.validate(f.manifestBytes,configuration:c,capability:f.capability)}
        }
        func altered(_ bytes:Data) throws {
            var cap=try JSONSerialization.jsonObject(with:ClusterRuntimeCapabilityCodec.encode(f.capability)) as! [String:Any]
            cap["manifestSHA256"]=ClusterConfigurationCodec.sha256(bytes)
            var encoded=try JSONSerialization.data(withJSONObject:cap,options:[.sortedKeys,.withoutEscapingSlashes]);encoded.append(10)
            let value=try ClusterRuntimeCapabilityCodec.decode(encoded)
            try rejected{_ = try DistributedInstalledManifest.validate(bytes,configuration:f.configuration,capability:value)}
        }
        var original=try JSONSerialization.jsonObject(with:f.manifestBytes) as! [String:Any]
        original["schema_version"]=true;try altered(JSONSerialization.data(withJSONObject:original))
        original=try JSONSerialization.jsonObject(with:f.manifestBytes) as! [String:Any];original["unexpected"]=1
        try altered(JSONSerialization.data(withJSONObject:original))
        original=try JSONSerialization.jsonObject(with:f.manifestBytes) as! [String:Any];original["total_size_bytes"]=1
        try altered(JSONSerialization.data(withJSONObject:original))
        let text=String(decoding:f.manifestBytes,as:UTF8.self)
        try altered(Data(text.replacingOccurrences(of:"\"schema_version\":1",with:"\"schema_version\":1,\"schema_version\":1").utf8))
        let environment=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL)
        try require(environment.count==9 && environment["JACCL_RANK"]=="0" && environment["MLX_ENABLE_TF32"]=="1","native environment widened")
        let local=try ClusterLocalOwnerConfiguration(installedDarkbloom:f.owner).launch()
        try require(local.arguments==["cluster","worker-owner","--stdio"] && local.environment.count==3,"local owner command widened")
        try rejected{_ = try ClusterLocalOwnerConfiguration(installedDarkbloom:URL(fileURLWithPath:"/unsafe/../owner"))}
    }
    static func fileAndProbeChecks(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        let deadline=DispatchTime.now().uptimeNanoseconds+2_000_000_000
        let file=f.root.appendingPathComponent("bounded-file");try Data("safe".utf8).write(to:file)
        let pin=ClusterConfigurationCodec.sha256(Data("safe".utf8))
        let held=try DistributedInstalledFiles.verify(file,expectedSHA256:pin,maximumBytes:4,deadline:deadline)
        try rejected{_ = try DistributedInstalledFiles.verify(file,expectedSHA256:pin,maximumBytes:3,deadline:deadline)}
        try rejected{_ = try DistributedInstalledFiles.verify(file,expectedSHA256:String(repeating:"0",count:64),maximumBytes:4,deadline:deadline)}
        try Data("edit".utf8).write(to:file);try rejected{try held.requireUnchanged()}
        let fifo=f.root.appendingPathComponent("fifo");try require(mkfifo(fifo.path,0o600)==0,"fifo create failed")
        try rejected{_ = try DistributedInstalledFiles.verify(fifo,expectedSHA256:pin,maximumBytes:4,deadline:deadline)}
        for behavior in ["--fixture-overflow","--fixture-stderr","--fixture-exit","--fixture-hang"] {
            try rejected{_ = try DistributedCapabilityProbe.run(executable:f.probe,arguments:[behavior],deadline:DispatchTime.now().uptimeNanoseconds+150_000_000)}
        }
        let fallback=prepared.model.directory.appendingPathComponent("chat_template.json");try Data("{}".utf8).write(to:fallback)
        try rejected{try prepared.requireUnchanged()};try FileManager.default.removeItem(at:fallback)
        try prepared.requireUnchanged()
    }
    static func session(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation,behavior:String="normal",failSecond:Bool=false) throws->(DistributedInstalledSession,EndpointBox) {
        let base=f.root.appendingPathComponent("session-"+UUID().uuidString);try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let box=EndpointBox()
        let session=try DistributedInstalledSession(prepared:prepared,endpointFactory:{ plan,id,rank,lifetime,relay in
            if failSecond && rank==1 { throw CheckFailure(message:"fabricated second launch refusal") }
            let directory=base.appendingPathComponent("rank-\(rank)");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let ready=base.appendingPathComponent("ready-\(rank).json")
            let frame=ClusterWorkerEventFrame(membershipEpoch:id.membershipEpoch,sequence:0,requestID:nil,
                event:.ready(.init(identity:id,rank:rank,profile:plan.capability.profile,executionPlanSHA256:plan.partition.planSHA256,requestCapacityBytes:1024)))
            try ClusterWorkerCodec.encode(frame).write(to:ready)
            let endpoint=try ClusterRemoteWorkerEndpoint(transport:.init(executable:f.owner,
                arguments:[f.worker.path,directory.path,String(rank),behavior],environment:["FIXTURE_READY_PATH":ready.path]),
                clusterID:plan.configuration.clusterID,expectedIdentity:id,profile:plan.capability.profile,rank:rank,
                executionPlanSHA256:plan.partition.planSHA256,lifetimeDeadlineUptimeNanoseconds:lifetime,bootstrapRelay:relay)
            box.add(endpoint);return endpoint
        })
        return(session,box)
    }
    static func request(_ session:DistributedInstalledSession,_ id:UInt64) throws->any DistributedResidentRequestLease {
        try session.reserve(.init(id:.init(id),promptTokens:[1,2,3],sampling:.init(temperature:0),maxTokens:2),
            identity:session.expectedIdentity,profileID:session.profile.id,capacityLimit:1800,
            deadlineContext:.init(generationDeadline:ContinuousClock.now.advanced(by:.seconds(100))))
    }
    static func normalAndDrain(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        let(s,box)=try session(f,p);try require(s.status == .prepared && s.readiness()==nil && !s.canRotate,"preparation fabricated readiness")
        try await s.start();try require(s.readiness() != nil && s.admissionState?.admissionsRemaining==16,"actual ready missing: status=\(s.status), state=\(String(describing:s.admissionState)), endpoints=\(box.snapshot.map { String(describing:$0.ownerTermination) + ":" + String(decoding:$0.diagnosticTail,as:UTF8.self) })")
        try require(s.admissionState!.remainingLifetimeNanoseconds < 10_000_000_000,"minimum endpoint lifetime lost")
        let lease=try request(s,1);try require(s.readiness() != nil,"post-reserve readiness falsely lost")
        try lease.start{_ in true};await lease.waitUntilRetired()
        let drain=Task { await s.drain(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000) }
        try await Task.sleep(for:.milliseconds(40))
        try require(s.admissionState?.hasActiveRequest==true && !s.canRotate && lease.bytesInUse>0,"retirement erased explicit release obligation")
        try rejected{_ = try request(s,2)}
        lease.releaseResources();let result=await drain.value;try require(result == .released,"clean drain lacked release: status=\(result), endpoints=\(box.snapshot.map { String(describing:$0.ownerTermination) + ":native=\($0.nativeCleanupObserved):ack=\($0.ownerDeviceLeaseReleasedObserved):" + String(decoding:$0.diagnosticTail,as:UTF8.self) })")
        try require(s.canRotate && box.snapshot.allSatisfy{$0.nativeCleanupObserved && $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)},"rotation preceded cleanup ACK and exit")
        do {try await s.start();throw CheckFailure(message:"session restarted")} catch DistributedEngineError.unavailable {}
    }
    static func exhausted(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        let(s,_)=try session(f,p);try await s.start()
        for id in 1...16 {
            let lease=try request(s,UInt64(id));try require(s.readiness() != nil,"last active reservation lost readiness")
            try lease.start{_ in true};await lease.waitUntilRetired();lease.releaseResources()
        }
        try require(s.admissionState?.admissionsRemaining==0 && s.readiness()==nil,"exhausted session advertised ready")
        try rejected{_ = try request(s,17)}
        try require(await s.drain(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000) == .released,"exhausted drain failed")
    }
    static func failedStart(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        let(s,box)=try session(f,p,failSecond:true)
        var refused = false
        do { try await s.start() }
        catch let error as CheckFailure where error.message == "fabricated second launch refusal" { refused = true }
        try require(refused, "second launch refusal accepted")
        let result=await s.stop(until:DispatchTime.now().uptimeNanoseconds+6_000_000_000)
        try require(box.snapshot.count==1 && box.snapshot[0].nativeCleanupObserved,"partial startup lost first endpoint")
        try require(result == .released || result == .quarantined,"partial startup returned live readiness")
        try require(!s.canRotate || box.snapshot[0].ownerDeviceLeaseReleasedObserved,"partial rotate missing release")
    }
    static func expired(_ f:InstalledFixture) async throws {
        let short=try InstalledFixture.make(root:f.root.appendingPathComponent("short-life"),probe:f.probe,owner:f.owner,worker:f.worker,lifetimeSeconds:1)
        let prepared=try short.prepare(),(s,box)=try session(short,prepared)
        try await s.start()
        guard let deadline=s.lifetimeDeadlineUptimeNanoseconds else {throw CheckFailure(message:"missing fixed lifetime")}
        let now=DispatchTime.now().uptimeNanoseconds
        if deadline>now {try await Task.sleep(nanoseconds:deadline-now+50_000_000)}
        try require(s.admissionState?.remainingLifetimeNanoseconds==0 && s.readiness()==nil,"expired lifetime advertised ready")
        try rejected{_ = try request(s,77)}
        let result=await s.stop(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000)
        try require(result == .quarantined || result == .released,"expired session kept accepting")
        try require(box.snapshot.allSatisfy(\.nativeCleanupObserved),"expired fixture child lacked actual terminal proof")
        try require(!s.canRotate || box.snapshot.allSatisfy{$0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)},"expiry substituted for owner release")
    }
    static func missingRelease(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        for behavior in ["drop-release","nonzero-owner"] {
            let(s,box)=try session(f,p,behavior:behavior);try await s.start()
            let result=await s.stop(until:DispatchTime.now().uptimeNanoseconds+3_000_000_000)
            try require(result == .quarantined && !s.canRotate && box.snapshot.allSatisfy(\.nativeCleanupObserved),"owner failure/release loss fabricated reusable slot")
            if behavior == "drop-release" {
                try require(box.snapshot.allSatisfy { !$0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0) },
                    "missing-ACK case did not reach the intended natural owner exit")
            } else {
                try require(box.snapshot.allSatisfy { $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(7) },
                    "nonzero-owner case did not retain the intended ACK and exit status")
            }
        }
    }
}
