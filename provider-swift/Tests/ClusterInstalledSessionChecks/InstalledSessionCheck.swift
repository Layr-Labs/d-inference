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
final class TokenBox: @unchecked Sendable {
    private let lock=NSLock()
    private var tokens:[(Int,Duration)]=[],finish:Duration?,failure=false
    func add(_ event:DistributedResidentEvent,at time:Duration) {
        lock.withLock {
            switch event {
            case .token(let token): tokens.append((token,time))
            case .finished(let reason): finish=time; if case .error = reason { failure=true }
            }
        }
    }
    static func milliseconds(_ value:Duration)->Int { Int(value.components.seconds*1000+value.components.attoseconds/1_000_000_000_000_000) }
    var count:Int { lock.withLock { tokens.count } }
    var values:[Int] { lock.withLock { tokens.map(\.0) } }
    var finished:Bool { lock.withLock { finish != nil } }
    var failed:Bool { lock.withLock { failure } }
    var gapsMilliseconds:[Int] { lock.withLock { tokens.indices.map { Self.milliseconds(tokens[$0].1-($0==0 ? .zero : tokens[$0-1].1)) } } }
    var lastTokenMilliseconds:Int { lock.withLock { Self.milliseconds(tokens.last?.1 ?? .zero) } }
    var finishMilliseconds:Int { lock.withLock { Self.milliseconds(finish ?? .zero) } }
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
        try pairedSetupRefusesLocalSession(fixture)
        try bootstrapSelection(fixture,prepared)
        try progressGuardIsRequired(fixture,prepared,unguarded:URL(fileURLWithPath:CommandLine.arguments[4]))
        try ordinaryProviderExclusion(fixture)
        try generationModeSelection(fixture,prepared)
        try perModelBudgets(fixture,prepared)
        try pairServingStaysWithheld(fixture)
        try unreadableCapabilityRecord(fixture)
        try await phaseSplitSession(fixture)
        try fileAndProbeChecks(fixture,prepared)
        try await normalAndDrain(fixture,prepared)
        try await exhausted(fixture,prepared)
        try await failedStart(fixture,prepared)
        try await missingRelease(fixture,prepared)
        try await expired(fixture)
        print("Installed owner/session: metadata, bootstrap selection, progress guard, provider exclusion, generation mode, per-model budgets, withheld pair serving, bounded IO and 7 lifecycle scenarios passed; no native model, SSH or network")
    }
    static func changedConfiguration(_ f:InstalledFixture,edit:(inout [String:Any])->Void) throws->ClusterConfiguration {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.configuration)) as! [String:Any];edit(&object)
        return try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:object),capability:f.capability,capabilitySHA256:f.configuration.capabilitySHA256)
    }
    /// A setup saved for coordinator pairing loads and validates, and the
    /// session this Mac would launch itself refuses it before any owner starts.
    static func pairedSetupRefusesLocalSession(_ f:InstalledFixture) throws {
        let root=f.root.deletingLastPathComponent().appendingPathComponent("installed-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let paired=try InstalledFixture.make(root:root,probe:f.probe,owner:f.owner,worker:f.worker,pairing:true)
        try require(paired.configuration.nativeMember != nil,"paired fixture lost its attachment")
        let prepared=try paired.prepare()
        try rejected{_ = try DistributedInstalledSession(prepared:prepared)}
        _ = try DistributedInstalledSession(prepared:try f.prepare())
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
        try require(environment.count==10 && environment["JACCL_RANK"]=="0" && environment["MLX_ENABLE_TF32"]=="1","native environment widened")
        try require(environment["JACCL_PROGRESS_TIMEOUT_MS"]=="60000","installed plan did not set the collective progress limit")
        let local=try ClusterLocalOwnerConfiguration(installedDarkbloom:f.owner).launch()
        try require(local.arguments==["cluster","worker-owner","--stdio"] && local.environment.count==3,"local owner command widened")
        try rejected{_ = try ClusterLocalOwnerConfiguration(installedDarkbloom:URL(fileURLWithPath:"/unsafe/../owner"))}
    }
    /// The installed build starts its ranks with the runtime's own bootstrap and
    /// says so. The owner-authenticated arguments stay a contract, not a default:
    /// they are appended only for a build that selects that exchange.
    static func bootstrapSelection(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        let plan=prepared.plan
        try require(plan.bootstrap == .directNative && plan.bootstrap.ownerProfile==nil && !plan.bootstrap.ownerAuthenticated,"installed bootstrap selection differs")
        let binding=try plan.binding(epoch:UUID(),lease:UUID(),incarnation:UUID())
        let deadline=DispatchTime.now().uptimeNanoseconds+100_000_000_000
        let direct=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:deadline-1,attachment:nil)
        try require(!direct.contains{$0.hasPrefix("--bootstrap-")},"direct native launch carried bootstrap arguments the worker refuses")
        try require(Array(direct.suffix(2))==["--startup-deadline-uptime-nanoseconds",String(deadline-1)],"startup deadline was not passed to the worker")
        let legacy=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:nil)
        try require(legacy==Array(direct.dropLast(2)) && legacy.count==24,"a worker without the startup argument must be started without it")
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:deadline+1,attachment:nil)}
        let attachment=try ClusterOwnerBootstrapAttachment(profile:.mesh2,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
        defer{attachment.cancel()}
        try require(attachment.workerArguments.count==6 && attachment.workerArguments[0]=="--bootstrap-socket-path","authenticated argument contract changed")
        // Supplying the attachment to a build that selected the direct exchange
        // is a mismatch, never a silent upgrade or downgrade.
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:attachment)}
        let (session,_)=try session(f,prepared)
        let observed=session.diagnosticObservation
        try require(observed.nativeBootstrap == .directNative && !observed.nativeBootstrapOwnerAuthenticated,"status claimed an authenticated bootstrap")
        try require(observed.collectiveProgressLimitMilliseconds==60_000,"status omitted the collective progress limit")
        try require(session.cooperativeStopAllowanceNanoseconds==75_000_000_000,"stop allowance does not cover the progress limit")
    }
    /// A pin names whatever binary was installed. The installed path also
    /// requires that binary to carry the collective progress guard.
    static func progressGuardIsRequired(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation,unguarded:URL) throws {
        try require(prepared.validation.workerFeatures == .init(hasProgressGuard:true,acceptsStartupDeadline:true),"guarded worker features were not read from its bytes")
        let bare=try InstalledFixture.make(root:f.root.appendingPathComponent("unguarded"),probe:unguarded,owner:f.owner,worker:f.worker)
        var refusal=""
        do { _ = try bare.prepare() } catch { refusal=String(describing:error) }
        try require(refusal.contains("no collective progress guard"),"a worker without the progress guard was accepted: \(refusal)")
        // The same refusal reaches `cluster doctor` and the owner, which share this validation.
        try rejected{_ = try DistributedInstalledValidation.validate(reference:bare.reference,paths:bare.paths,deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)}
        try rejected{try DistributedInstalledWorkerFeatures(hasProgressGuard:false,acceptsStartupDeadline:true).requireProgressGuard()}
    }
    /// The owner refuses while this Mac's ordinary provider holds its instance lock.
    static func ordinaryProviderExclusion(_ f:InstalledFixture) throws {
        let lock=f.root.appendingPathComponent("provider.pid.lock")
        func check(parent:Int32=1,arguments:[String]?=["darkbloom","start"]) throws {
            try DistributedInstalledProviderExclusion.requireNoOrdinaryProvider(lockFile:lock,parent:parent,arguments:{_ in arguments})
        }
        try check() // No provider has ever run here.
        let descriptor=open(lock.path,O_RDWR|O_CREAT|O_CLOEXEC,0o600);try require(descriptor>=0,"lock fixture")
        defer{close(descriptor)}
        let record=Data("{\"acquired_at\":1,\"operation\":\"provider-instance\",\"pid\":4242}\n".utf8)
        try require(record.withUnsafeBytes{write(descriptor,$0.baseAddress,$0.count)}==record.count,"lock record fixture")
        try check() // A record left by a provider that has exited holds nothing.
        try require(flock(descriptor,LOCK_EX|LOCK_NB)==0,"lock fixture")
        var message=""
        do { try check() } catch { message=String(describing:error) }
        try require(message.contains("process 4242") && message.contains("darkbloom stop"),"ordinary provider was not refused clearly: \(message)")
        try check(parent:4242) // The leader that launched this owner holds the lock for its own session.
        try check(arguments:["darkbloom","start","--cluster-member"]) // A control-only member serves nothing itself.
        try rejected{try check(arguments:nil)} // A holder that cannot be identified is not assumed to be a member.
        try require(ftruncate(descriptor,0)==0,"lock fixture");try rejected{try check(parent:4242)} // No record: nothing proves who holds it.
        try require(flock(descriptor,LOCK_UN)==0,"lock fixture");try check()
    }
    static let allModes:[ClusterGenerationMode]=[.pipeline,.pipelineCompactDecode,.phaseSplit]
    static func refusal(_ body:() throws->Void) throws->String {
        do { try body() } catch is CheckFailure { throw CheckFailure(message:"assertion inside refusal") } catch { return String(describing:error) }
        throw CheckFailure(message:"expected refusal")
    }
    /// The saved setup names the mode. The pipeline is the absence of the
    /// argument; any other mode reaches both ranks only when the pinned record
    /// advertises it, and is refused before launch when it does not.
    static func generationModeSelection(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        let plan=prepared.plan
        try require(plan.configuration.generationMode==nil && plan.configuration.selectedGenerationMode == .pipeline,"an existing setup must run the pipeline")
        let saved=try Data(contentsOf:URL(fileURLWithPath:f.reference.configuration))
        try require(!String(decoding:saved,as:UTF8.self).contains("generationMode"),"an existing setup's saved bytes gained a field")
        try require(try DistributedInstalledGenerationSelection.workerArguments(configuration:plan.configuration,capability:plan.capability).isEmpty,
            "the pipeline must be the absence of the argument")
        // Naming the pipeline is the same setup, byte for byte.
        let named=try InstalledFixture.make(root:f.root.appendingPathComponent("named-pipeline"),probe:f.probe,owner:f.owner,worker:f.worker,generationMode:"pipeline_v1")
        let namedBytes=try Data(contentsOf:URL(fileURLWithPath:named.reference.configuration))
        try require(!String(decoding:namedBytes,as:UTF8.self).contains("generationMode")
            && (try ClusterConfigurationStore(paths:named.paths).load(reference:named.reference)).configuration.generationMode==nil,
            "naming the pipeline produced a second saved spelling of the same setup")
        // A mode the worker's record does not advertise is refused when the setup is read.
        let refused=try refusal{_ = try InstalledFixture.make(root:f.root.appendingPathComponent("unadvertised"),probe:f.probe,owner:f.owner,worker:f.worker,generationMode:"phase_split_v1")}
        try require(refused.contains("phase_split_v1") && refused.contains("member peer-0") && refused.contains(f.probe.path) && refused.contains("which advertises: pipeline_v1"),
            "refusal did not name the mode and the worker: \(refused)")
        try rejected{_ = try InstalledFixture.make(root:f.root.appendingPathComponent("unknown-mode"),probe:f.probe,owner:f.owner,worker:f.worker,generationMode:"phase_split")}
        // Advertised: both ranks get the argument, once, and the status says so.
        let split=try InstalledFixture.make(root:f.root.appendingPathComponent("phase-split"),probe:f.probe,owner:f.owner,worker:f.worker,
            generationMode:"phase_split_v1",advertisedModes:allModes)
        let splitPrepared=try split.prepare(),splitPlan=splitPrepared.plan
        try require(String(decoding:try Data(contentsOf:URL(fileURLWithPath:split.reference.configuration)),as:UTF8.self).contains("\"generationMode\":\"phase_split_v1\""),"selected mode was not saved")
        let deadline=DispatchTime.now().uptimeNanoseconds+100_000_000_000
        for rank in 0..<2 {
            // The follower builds the same arguments from its own saved setup.
            let object=try JSONSerialization.jsonObject(with:Data(contentsOf:split.root.appendingPathComponent("input.json"))) as! [String:Any]
            var member=object;if rank==1 { member["memberID"]="peer-1";member["role"]="follower" }
            let configuration=try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:member),capability:split.capability,capabilitySHA256:split.configuration.capabilitySHA256)
            let rankPlan=try DistributedInstalledPlan(saved:.init(configuration:configuration,capability:split.capability),paths:split.paths)
            let binding=try rankPlan.binding(epoch:UUID(),lease:UUID(),incarnation:UUID())
            let arguments=try rankPlan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:nil)
            // The same setup without the field: the pipeline's command line, to which the mode adds exactly one pair.
            member.removeValue(forKey:"generationMode")
            let pipeline=try DistributedInstalledPlan(saved:.init(configuration:ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:member),
                capability:split.capability,capabilitySHA256:split.configuration.capabilitySHA256),capability:split.capability),paths:split.paths)
            let plain=try pipeline.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:nil)
            try require(arguments==plain+["--generation-mode","phase_split_v1"] && !plain.contains("--generation-mode"),
                "rank \(rank) was not started with the pipeline's arguments plus the selected mode: \(arguments)")
            try require(!arguments.contains("--qualification-switches"),"the owner passed a qualification switch")
        }
        let binding=try ClusterStatusBinding(configuration:splitPlan.configuration,capability:splitPlan.capability)
        try require(binding.generationMode == .phaseSplit && binding.peers.allSatisfy{$0.supportedGenerationModes==allModes},"status binding omitted the mode or the workers' support")
        try require(try ClusterStatusBinding(configuration:plan.configuration,capability:plan.capability).peers.allSatisfy{$0.supportedGenerationModes==[.pipeline]},
            "a pipeline-only worker was reported as supporting more")
        // A record that describes another build covers neither worker.
        let other=ClusterConfiguration.Peer(id:"peer-9",rank:1,host:"peer-9.local",port:22,user:"fixture",ownerExecutable:"/o",workerExecutable:"/w",
            modelDirectory:"/m",runtimeBinarySHA256:String(repeating:"9",count:64),jacclDevice:"rdma_en9")
        try require(ClusterGenerationSelection.supportedModes(for:other,capability:split.capability).isEmpty,"a record was applied to a worker it does not describe")
        let foreign=try refusal{try ClusterGenerationSelection.requireSupport(for:.pipeline,peers:[other],capability:split.capability)}
        try require(foreign.contains("member peer-9") && foreign.contains("nothing in the saved record"),"foreign worker refusal: \(foreign)")
    }
    /// The model-dependent waits come from the selected registered model's
    /// row. The 9B's are the figures the path has always used.
    static func perModelBudgets(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        typealias Table=DistributedInstalledPairServingTable
        let nine=DistributedInstalledTimeBudgets(startupAllowanceNanoseconds:90_000_000_000,firstTokenBaseMilliseconds:10_000,firstTokenMillisecondsPerPromptToken:1,
            admissionWaitNanoseconds:5_000_000_000,shutdownAcknowledgementNanoseconds:2_000_000_000,stopMarginNanoseconds:15_000_000_000)
        try require(Table.qwen35.pairServing == .open(nine),"the 9B's budgets changed, or the 9B is no longer open")
        try require(prepared.plan.budgets==nine,"the plan did not take its budgets from the selected model's row")
        try require(nine.pairTiming == .standard,"the 9B's pair timing differs from the process module's standing values")
        let (session,_)=try session(f,prepared)
        try require(try session.firstTokenBudgetPolicy() == DistributedFirstTokenBudgetPolicy(baseMilliseconds:10_000,millisecondsPerInputToken:1),"9B first-token budget changed")
        try require(session.cooperativeStopAllowanceNanoseconds==75_000_000_000,"9B stop allowance changed")
        // The mode does not enter the budgets: a phase-split setup of the same model gets the same row.
        let split=try InstalledFixture.make(root:f.root.appendingPathComponent("budget-split"),probe:f.probe,owner:f.owner,worker:f.worker,
            generationMode:"phase_split_v1",advertisedModes:allModes).prepare()
        try require(split.plan.budgets==nine,"the generation mode changed a time budget")
        // The 27B's row is withheld; its groundwork figures follow from its own measurements.
        guard case .withheld(let big)=Table.qwen38.pairServing else { throw CheckFailure(message:"the 27B's row is not withheld") }
        let slowestStageLoad=13.7,phaseSplitFactor=12.3/7.3,slowPrefillTokensPerSecond=300.0
        try require(Double(big.startupAllowanceNanoseconds)/1e9 >= 5*slowestStageLoad*phaseSplitFactor
            && big.startupAllowanceNanoseconds <= 150_000_000_000,"27B startup allowance is not five whole-model loads inside half a session")
        try require(Double(big.firstTokenMillisecondsPerPromptToken) >= 1000/slowPrefillTokensPerSecond
            && big.firstTokenMillisecondsPerPromptToken > nine.firstTokenMillisecondsPerPromptToken,"27B first-token rate is faster than its slower Mac alone")
        try require(big.firstTokenBaseMilliseconds+8192*big.firstTokenMillisecondsPerPromptToken==42_768,"27B first-token budget at 8,192 tokens")
        try require(nine.firstTokenBaseMilliseconds+8192*nine.firstTokenMillisecondsPerPromptToken==18_192,"9B first-token budget at 8,192 tokens")
        try require(big.shutdownAcknowledgementNanoseconds==3*nine.shutdownAcknowledgementNanoseconds
            && big.stopMarginNanoseconds>nine.stopMarginNanoseconds && big.admissionWaitNanoseconds==nine.admissionWaitNanoseconds,"27B release and admission waits")
        // Every model the runtime registers has exactly one row.
        let registered=ClusterRuntimeAdapter.qwen35Dense.registeredProfiles.map(\.runtimeModelID)
        try require(Table.rows.map(\.runtimeModelID)==registered,"the table and the runtime's registered models differ")
    }
    /// The 27B is not open to pair serving. Nothing in the installed path can
    /// start it: not a setup, not a mode, not its budgets.
    static func pairServingStaysWithheld(_ f:InstalledFixture) throws {
        typealias Table=DistributedInstalledPairServingTable
        let model=("registered_qwen38_27b","registered_qwen38_27b_greedy_generation_v1","EigenLabs/Qwen3.8-27B-4bit-mtp")
        func isPolicy(_ message:String)->Bool {
            message.contains("EigenLabs/Qwen3.8-27B-4bit-mtp") && message.contains("registered_qwen38_27b") && message.contains("not open to serving on a two-Mac pair")
                && message.contains("policy decision") && message.contains("generation mode or time budget")
        }
        for (name,mode) in [("q27",nil),("q27-split","phase_split_v1")] as [(String,String?)] {
            // Saving a setup is not serving it, and stays possible.
            let big=try InstalledFixture.make(root:f.root.appendingPathComponent(name),probe:f.probe,owner:f.owner,worker:f.worker,
                generationMode:mode,advertisedModes:allModes,registered:model)
            let prepare=try refusal{_ = try big.prepare()}
            try require(isPolicy(prepare),"27B refusal does not say why: \(prepare)")
            try require(isPolicy(try refusal{_ = try DistributedInstalledValidation.validate(reference:big.reference,paths:big.paths,deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)}),
                "the shared validation did not refuse the 27B as policy")
            try require(isPolicy(try refusal{_ = try DistributedInstalledPlan(saved:.init(configuration:big.configuration,capability:big.capability),paths:big.paths)}),
                "a plan exists for a model that is not served on a pair")
        }
        // The refusal is keyed on the runtime's model, whatever the public name; a model without a row is refused too.
        let withheld=try refusal{_ = try Table.servingBudgets(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")}
        try require(withheld.contains("renamed/public-id") && withheld.contains("registered_qwen38_27b") && withheld.contains("policy decision"),"renamed 27B: \(withheld)")
        let unknown=try refusal{_ = try Table.servingBudgets(runtimeModelID:"registered_future",publicModelID:"future/model")}
        try require(unknown.contains("no row for the registered model registered_future"),"a model without a row must be refused: \(unknown)")
    }
    /// A worker whose description this build cannot read is a mixed install,
    /// and the refusal says so instead of reporting a difference.
    static func unreadableCapabilityRecord(_ f:InstalledFixture) throws {
        let mixed=try InstalledFixture.make(root:f.root.appendingPathComponent("mixed-install"),probe:f.probe,owner:f.owner,worker:f.worker)
        let described=mixed.root.appendingPathComponent("model/fixture-capability.json")
        var record=try JSONSerialization.jsonObject(with:Data(contentsOf:described)) as! [String:Any]
        record["supportedGenerationModes"]=["pipeline_v1","a_mode_from_a_newer_worker_v1"]
        var bytes=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.withoutEscapingSlashes]);bytes.append(10)
        try bytes.write(to:described)
        let message=try refusal{_ = try mixed.prepare()}
        try require(message.contains("cannot read the capability record written by the installed worker") && message.contains(f.probe.path)
            && message.contains("Unknown generation mode") && message.contains("not built from the same tree") && message.contains("cluster configure"),
            "mixed install was not explained: \(message)")
        record.removeValue(forKey:"supportedGenerationModes");record["aFieldFromANewerWorker"]=1
        bytes=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.withoutEscapingSlashes]);bytes.append(10)
        try bytes.write(to:described)
        try require(try refusal{_ = try mixed.prepare()}.contains("not built from the same tree"),"an unknown field was not explained")
        // A readable record that differs is a changed worker, a different sentence.
        record.removeValue(forKey:"aFieldFromANewerWorker");record["maxRequests"]=15
        bytes=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.withoutEscapingSlashes]);bytes.append(10)
        try bytes.write(to:described)
        let changed=try refusal{_ = try mixed.prepare()}
        try require(changed.contains("differs from the saved capability") && !changed.contains("same tree"),"changed worker: \(changed)")
    }
    /// A phase-split session as its owner sees it: tokens reach rank 0 in
    /// batches with a pause before each, and a client stop takes effect only
    /// after rank 1's next batch boundary. The session stays ready throughout.
    /// The stand-in workers imitate that cadence; they are not told the mode.
    /// What depends on the mode here is the reported running mode; the rest
    /// shows that the unchanged request path holds under the mode's timing.
    static func phaseSplitSession(_ f:InstalledFixture) async throws {
        let split=try InstalledFixture.make(root:f.root.appendingPathComponent("split-session"),probe:f.probe,owner:f.owner,worker:f.worker,
            generationMode:"phase_split_v1",advertisedModes:allModes)
        let(s,box)=try session(split,try split.prepare(),behavior:"workers:batched,clean-stop")
        try require(s.diagnosticObservation.observedGenerationMode==nil,"a mode was reported as running before both ranks were ready")
        try await s.start()
        let observed=s.diagnosticObservation
        try require(observed.observedGenerationMode == .phaseSplit && observed.binding.generationMode == .phaseSplit && observed.ready,"running mode not reported")
        let tokens=TokenBox()
        let lease=try s.reserve(.init(id:.init(1),promptTokens:[1,2,3],sampling:.init(temperature:0),maxTokens:24),
            identity:s.expectedIdentity,profileID:s.profile.id,capacityLimit:1800,
            deadlineContext:.init(generationDeadline:ContinuousClock.now.advanced(by:.seconds(8)),firstTokenDeadline:ContinuousClock.now.advanced(by:.seconds(2))))
        let begin=ContinuousClock.now
        // The client stops after the eleventh token, inside the fourth batch.
        try lease.start{event in tokens.add(event,at:ContinuousClock.now-begin); return tokens.count<11}
        await lease.waitUntilRetired();lease.releaseResources()
        try require(tokens.values==Array(9..<20),"published tokens differ from the accepted ones: \(tokens.values)")
        try require(tokens.finished && !tokens.failed,"a client stop at a batch boundary was not a clean finish")
        // Batches of 1, 2, 4 and 8: the stand-in pauses 80 ms before tokens 1, 3 and 7.
        let gaps=tokens.gapsMilliseconds
        try require([1,3,7].allSatisfy{gaps[$0]>=60},"tokens did not arrive in batches: \(gaps)")
        try require(tokens.finishMilliseconds-tokens.lastTokenMilliseconds>=200,"the stop took effect before the stand-in's batch boundary")
        try require(s.readiness() != nil && s.status == .ready && box.snapshot.allSatisfy{!$0.nativeCleanupObserved},"a clean phase-split stop cost the session")
        // The stand-in for rank 1 always reports a client stop, so the second request stops too.
        let again=try request(s,2);try again.start{_ in false};await again.waitUntilRetired();again.releaseResources()
        try require(s.readiness() != nil && s.admissionState?.admissionsRemaining==14,"the session was not reusable after a batched request")
        try require(await s.drain(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000) == .released,"phase-split session did not release")
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
