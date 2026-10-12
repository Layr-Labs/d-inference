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
func rejected(line:Int = #line,_ body:() throws->Void) throws {
    do { try body() } catch is CheckFailure { throw CheckFailure(message:"assertion inside refusal at line \(line)") } catch { return }
    throw CheckFailure(message:"expected refusal at line \(line)")
}
final class TokenBox: @unchecked Sendable {
    private let lock=NSLock()
    private var tokens:[(Int,Duration)]=[],finish:Duration?,failure=false
    func add(_ event:DistributedResidentEvent,at time:Duration) {
        lock.withLock {
            switch event {
            case .token(let token): tokens.append((token,time))
            case .finished(let reason): finish=time; if case .error = reason { failure=true }
            case .promptCache: break
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
final class NoticeBox: @unchecked Sendable {
    struct Entry { let value:DistributedInstalledStopNotice; let at:ContinuousClock.Instant; let running:[Int] }
    private let lock=NSLock(); private var values:[Entry]=[]
    func add(_ value:DistributedInstalledStopNotice,running:[Int]){ lock.withLock { values.append(.init(value:value,at:.now,running:running)) } }
    var count:Int { lock.withLock { values.count } }
    var first:Entry? { lock.withLock { values.first } }
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
        try longPromptsFitTheInstalledSession(fixture)
        try pairServingGrant(fixture)
        try adaptersOnTheInstalledPath(fixture)
        try unreadableCapabilityRecord(fixture)
        try await phaseSplitSession(fixture)
        try fileAndProbeChecks(fixture,prepared)
        try await normalAndDrain(fixture,prepared)
        try await noRequestLimit(fixture,prepared)
        try await failedStart(fixture,prepared)
        try await missingRelease(fixture,prepared)
        try await outlivesFirstGrant(fixture)
        try await stopNotice(fixture,prepared)
        print("Installed owner/session: metadata, bootstrap selection, progress guard, provider exclusion, generation mode, per-model budgets, long prompts within the request budgets, per-model pair-serving grants by chip class, bounded IO and 8 lifecycle scenarios passed; no native model, SSH or network")
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
        // A startup may outlast the first lease grant (the lease is renewed
        // during the load), but not the protocol's hour; a first grant is at
        // most one lease grant away.
        _ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:deadline+1,attachment:nil)
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:DispatchTime.now().uptimeNanoseconds+3_601_000_000_000,attachment:nil)}
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:DispatchTime.now().uptimeNanoseconds+121_000_000_000,startupDeadline:nil,attachment:nil)}
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
        try require(session.cooperativeStopAllowanceNanoseconds==85_000_000_000,"stop allowance does not cover the clean-stop wait and the progress limit")
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
            admissionWaitNanoseconds:5_000_000_000,shutdownAcknowledgementNanoseconds:2_000_000_000,stopMarginNanoseconds:15_000_000_000,
            cleanStopWaitNanoseconds:10_000_000_000)
        try require(Table.qwen35.budgets == nine,"the 9B's budgets changed")
        try require(prepared.plan.budgets==nine,"the plan did not take its budgets from the selected model's row")
        try require(nine.pairTiming == ClusterWorkerPairTiming(admissionWaitNanoseconds:5_000_000_000,shutdownAcknowledgementNanoseconds:2_000_000_000,cleanStopWaitNanoseconds:10_000_000_000),"the 9B's pair timing differs from its row")
        let (session,_)=try session(f,prepared)
        try require(try session.firstTokenBudgetPolicy() == DistributedFirstTokenBudgetPolicy(baseMilliseconds:10_000,millisecondsPerInputToken:1),"9B first-token budget changed")
        try require(session.cooperativeStopAllowanceNanoseconds==85_000_000_000,"9B stop allowance changed")
        // The mode does not enter the budgets: a phase-split setup of the same model gets the same row.
        let split=try InstalledFixture.make(root:f.root.appendingPathComponent("budget-split"),probe:f.probe,owner:f.owner,worker:f.worker,
            generationMode:"phase_split_v1",advertisedModes:allModes).prepare()
        try require(split.plan.budgets==nine,"the generation mode changed a time budget")
        // The 27B's row is open (S08); its figures follow from its own measurements.
        let big=Table.qwen38.budgets
        let slowestStageLoad=13.7,phaseSplitFactor=12.3/7.3,slowPrefillTokensPerSecond=300.0
        try require(Double(big.startupAllowanceNanoseconds)/1e9 >= 5*slowestStageLoad*phaseSplitFactor
            && big.startupAllowanceNanoseconds <= 150_000_000_000,"27B startup allowance is not five whole-model loads inside half a session")
        try require(Double(big.firstTokenMillisecondsPerPromptToken) >= 1000/slowPrefillTokensPerSecond
            && big.firstTokenMillisecondsPerPromptToken > nine.firstTokenMillisecondsPerPromptToken,"27B first-token rate is faster than its slower Mac alone")
        try require(big.firstTokenBaseMilliseconds+8192*big.firstTokenMillisecondsPerPromptToken==42_768,"27B first-token budget at 8,192 tokens")
        try require(nine.firstTokenBaseMilliseconds+8192*nine.firstTokenMillisecondsPerPromptToken==18_192,"9B first-token budget at 8,192 tokens")
        try require(big.shutdownAcknowledgementNanoseconds==3*nine.shutdownAcknowledgementNanoseconds
            && big.stopMarginNanoseconds>nine.stopMarginNanoseconds && big.admissionWaitNanoseconds==nine.admissionWaitNanoseconds,"27B release and admission waits")
        // Every model with a pair-serving grant has exactly one row, in the grants' order; a model
        // whose grant is withheld has none, so neither half alone can open it.
        try require(Table.rows.map(\.runtimeModelID)==ClusterPairServingGrants.granted.map(\.runtimeModelID),"the table's rows and the granted models differ")
        for model in ClusterPairServingGrants.withheld.keys {
            let none=try refusal{_ = try Table.servingBudgets(runtimeModelID:model,publicModelID:"p")}
            try require(none.contains("no row for the registered model \(model)"),"a withheld model has a row: \(model)")
        }
        // The rows opened with the other granted families: each allowance covers what the pair measured
        // across the cable (seconds: slowest start in any mode, the slower Mac's prefill rate alone).
        let family:[(DistributedInstalledPairServingTable.Row,slowestStart:Double,slowPrefillTokensPerSecond:Double)]=[
            (Table.qwen35A3B,29.0,1460),(Table.qwen36A3B,30.6,1730),(Table.bonsai2,11.8,278),(Table.nemotron35,19.7,1749)]
        for (row,slowestStart,slowPrefill) in family {
            let b=row.budgets
            try require(Double(b.startupAllowanceNanoseconds)/1e9 >= 4.9*slowestStart && b.startupAllowanceNanoseconds<=150_000_000_000,"\(row.runtimeModelID): startup allowance")
            try require(Double(b.firstTokenMillisecondsPerPromptToken) >= 1000/slowPrefill,"\(row.runtimeModelID): first-token rate is faster than its slower Mac alone")
            try require(b.firstTokenBaseMilliseconds==nine.firstTokenBaseMilliseconds && b.admissionWaitNanoseconds==nine.admissionWaitNanoseconds
                && b.shutdownAcknowledgementNanoseconds>=nine.shutdownAcknowledgementNanoseconds && b.stopMarginNanoseconds>=nine.stopMarginNanoseconds,"\(row.runtimeModelID): release and admission waits")
        }
    }
    /// No session lifetime (handoff/DESIGN-no-fixed-lifetime.md): a long
    /// prompt with 128 outputs is bounded only by each row's own request
    /// budgets. The pair's measured first token at the longest prompt each
    /// model has run across the cable (both Macs, normal order) is inside its
    /// row's first-token budget.
    static func longPromptsFitTheInstalledSession(_ f:InstalledFixture) throws {
        typealias Table=DistributedInstalledPairServingTable
        // 9B and 27B at 30,720 prompt tokens, medians after one warm-up (evidence/longctx-20261009, hw-9b
        // and hw-27b TABLE.txt): the slower Mac decoding alone, tokens a second (9B 67.6, 27B 23.3, both
        // Mac B), rounded down; the pair's first token in the pipeline mode, seconds, rounded up. The
        // other families at 16,384 tokens, one run each (evidence/universal-20261010/hw/<family>/p16k-*).
        let measured:[String:(prompt:Int,decode:Double,pairFirstToken:Double)]=["registered_qwen35_9b":(30_720,67,15.61),
            "registered_qwen38_27b":(30_720,23,39.91),"registered_qwen35_35b_a3b":(16_384,65,8.68),
            "registered_qwen36_35b_a3b":(16_384,65,8.33),"registered_ternary_bonsai_2_27b":(16_384,29,45.52),
            "registered_nemotron35_lightning":(16_384,77,8.28)]
        for row in Table.rows {
            let budgets=row.budgets
            guard let rates=measured[row.runtimeModelID] else { throw CheckFailure(message:"no measured rates for \(row.runtimeModelID)") }
            let firstToken=Double(budgets.firstTokenBaseMilliseconds+Int64(rates.prompt)*budgets.firstTokenMillisecondsPerPromptToken)/1000
            try require(rates.pairFirstToken<firstToken,"\(row.runtimeModelID): measured first token \(rates.pairFirstToken) s exceeds its \(firstToken) s budget")
        }
    }
    /// Pair serving is granted per registered model with the chip classes each
    /// role may run on (owner decision D4). The 27B is granted on the M3 Ultra
    /// and the M5 Max for either role: its setups prepare in every mode, under
    /// its own budgets, whatever the public name, and the plan admits exactly
    /// the listed classes for the rank it runs. A registered model without a
    /// row is still refused.
    static func pairServingGrant(_ f:InstalledFixture) throws {
        typealias Table=DistributedInstalledPairServingTable
        let model=("registered_qwen38_27b","registered_qwen38_27b_greedy_generation_v1","EigenLabs/Qwen3.8-27B-4bit-mtp")
        for (name,mode) in [("q27",nil),("q27-split","phase_split_v1")] as [(String,String?)] {
            let big=try InstalledFixture.make(root:f.root.appendingPathComponent(name),probe:f.probe,owner:f.owner,worker:f.worker,
                generationMode:mode,advertisedModes:allModes,registered:model)
            let prepared=try big.prepare()
            try require(prepared.plan.budgets==Table.qwen38.budgets,"the 27B was prepared under another row's budgets")
            try require(prepared.plan.grant==ClusterPairServingGrants.qwen38_27b,"the 27B was prepared under another model's grant")
            // The fixture is the leader: rank 0 of two, the pipeline-only rank.
            for chip in ["Apple M3 Ultra","Apple M5 Max"] { try prepared.plan.requireLocalRankGranted(chipClass:ClusterChipClass(chipName:chip)) }
            for chip in ["Apple M4 Max","Apple M5 Pro","Apple M1 (Virtual)"] {
                let refused=try refusal{try prepared.plan.requireLocalRankGranted(chipClass:ClusterChipClass(chipName:chip))}
                try require(refused.contains("EigenLabs/Qwen3.8-27B-4bit-mtp") && refused.contains("registered_qwen38_27b") && refused.contains("rank 0")
                    && refused.contains("policy decision"),"\(chip) was not refused for the 27B's rank 0: \(refused)")
            }
        }
        // The 9B was checked with the M3 Ultra leading only: an M5 Max cannot run its rank 0.
        let nine=try f.prepare()
        try require(nine.plan.grant==ClusterPairServingGrants.qwen35_9b,"the 9B was prepared under another model's grant")
        try nine.plan.requireLocalRankGranted(chipClass:.appleM3Ultra)
        let led=try refusal{try nine.plan.requireLocalRankGranted(chipClass:.appleM5Max)}
        try require(led.contains("pipeline-only rank on apple_m3_ultra") && led.contains("apple_m5_max"),"9B led by the M5 Max: \(led)")
        // Budgets and grant are keyed on the runtime's model, whatever the public name.
        let renamed=try Table.servingBudgets(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")
        try require(renamed==Table.qwen38.budgets,"renamed 27B budgets differ")
        try require(try ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")==ClusterPairServingGrants.qwen38_27b,
            "renamed 27B grant differs")
        let unknown=try refusal{_ = try Table.servingBudgets(runtimeModelID:"registered_future",publicModelID:"future/model")}
        try require(unknown.contains("no row for the registered model registered_future"),"a model without a row must be refused: \(unknown)")
        let ungranted=try refusal{_ = try ClusterPairServingGrants.grant(runtimeModelID:"registered_future",publicModelID:"EigenLabs/Qwen3.8-27B-4bit-mtp")}
        try require(ungranted.contains("has no grant") && ungranted.contains("registered_future"),"a model without a grant must be refused: \(ungranted)")
    }
    /// The installed path starts workers for the adapter of every granted
    /// model, each with the rank environment its arithmetic policy requires
    /// beside the values every rank is given, under that model's own budgets
    /// and grant; and for no other adapter.
    static func adaptersOnTheInstalledPath(_ f:InstalledFixture) throws {
        typealias Table=DistributedInstalledPairServingTable
        let cases:[(String,ClusterRuntimeAdapter,String,[String:String],DistributedInstalledTimeBudgets)]=[
            ("a35",.qwen35RoutedExperts,"registered_qwen35_35b_a3b",["MLX_GATHER_QMM_EXPERT_SLICES":"trust"],Table.qwen35A3B.budgets),
            ("a36",.qwen35RoutedExperts,"registered_qwen36_35b_a3b",["MLX_GATHER_QMM_EXPERT_SLICES":"trust"],Table.qwen36A3B.budgets),
            ("bonsai",.qwen35PrismHadamard,"registered_ternary_bonsai_2_27b",
                ["DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC":"1","DARKBLOOM_BONSAI_F16_CONSTANT_CACHE":"1"],Table.bonsai2.budgets),
            ("nemotron",.nemotronH,"registered_nemotron35_lightning",[:],Table.nemotron35.budgets)]
        for (name,adapter,model,extra,budgets) in cases {
            let fixture=try InstalledFixture.make(root:f.root.appendingPathComponent("adapter-"+name),probe:f.probe,owner:f.owner,worker:f.worker,
                generationMode:"phase_split_v1",advertisedModes:allModes,registered:(model,model+"_greedy_generation_v1","fixture/"+name),adapter:adapter)
            let prepared=try fixture.prepare()
            let environment=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL)
            try require(environment.count==10+extra.count && extra.allSatisfy{environment[$0.key]==$0.value}
                && environment["MLX_ENABLE_TF32"]=="1" && environment["DARKBLOOM_BF16_WEIGHTS"]=="1" && environment["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"]=="128"
                && environment["JACCL_RANK"]=="0" && environment["JACCL_PROGRESS_TIMEOUT_MS"]=="60000","\(name): rank environment \(environment.keys.sorted())")
            try require(prepared.plan.budgets==budgets && prepared.plan.grant.runtimeModelID==model,"\(name) was prepared under another model's budgets or grant")
            // The fixture is the leader: rank 0, which these grants list on the M3 Ultra only.
            try prepared.plan.requireLocalRankGranted(chipClass:.appleM3Ultra)
            let led=try refusal{try prepared.plan.requireLocalRankGranted(chipClass:.appleM5Max)}
            try require(led.contains("pipeline-only rank on apple_m3_ultra") && led.contains(model),"\(name) led by the M5 Max: \(led)")
        }
        // The dense adapter's environment is the ten values it always had.
        try require(try f.prepare().plan.adapterEnvironment.isEmpty,"the dense adapter gained an environment value")
        // An adapter value can never replace one of the fixed ten.
        try require(DistributedInstalledPlan.adapterArithmeticEnvironment.values.allSatisfy{$0.keys.allSatisfy{key in
            !["PATH","LANG","LC_ALL","DARKBLOOM_CBV2_ATTN_QUERY_BLOCK","DARKBLOOM_BF16_WEIGHTS","MLX_ENABLE_TF32","JACCL_RANK","JACCL_IBV_DEVICES",
              "JACCL_COORDINATOR","JACCL_PROGRESS_TIMEOUT_MS"].contains(key)}},"an adapter names a fixed environment value")
        // The adapters this path starts are exactly the adapters of the granted models.
        let granted=Set(ClusterPairServingGrants.granted.compactMap{ClusterRuntimeAdapter.registering(runtimeModelID:$0.runtimeModelID)})
        try require(Set(DistributedInstalledPlan.adapterArithmeticEnvironment.keys)==granted,"the installed path's adapters and the granted models' adapters differ")
        // A model whose grant is withheld is refused before its adapter is looked at.
        let withheld=try InstalledFixture.make(root:f.root.appendingPathComponent("adapter-gptoss"),probe:f.probe,owner:f.owner,worker:f.worker,
            registered:("registered_gpt_oss_20b","registered_gpt_oss_20b_greedy_generation_v1","fixture/gptoss"),adapter:.gptossLayerStage)
        let refused=try refusal{_ = try withheld.prepare()}
        try require(refused.contains("is not granted pair serving") && refused.contains("registered_gpt_oss_20b"),"a withheld model on its own adapter: \(refused)")
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
        record.removeValue(forKey:"aFieldFromANewerWorker");record["arithmeticPolicySHA256"]=String(repeating:"e",count:64)
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
        try require(s.readiness() != nil && s.admissionState?.requestsServed==2,"the session was not reusable after a batched request")
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
        try await s.start();try require(s.readiness() != nil && s.admissionState?.requestsServed==0,"actual ready missing: status=\(s.status), state=\(String(describing:s.admissionState)), endpoints=\(box.snapshot.map { String(describing:$0.ownerTermination) + ":" + String(decoding:$0.diagnosticTail,as:UTF8.self) })")
        // No fixed lifetime: the endpoints' leases are renewed while the session runs.
        try require(s.admissionState!.isValid,"a fresh session was not valid")
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
    /// No request count: a session serves more requests than the old cap of
    /// sixteen and stays ready, then drains and releases cleanly.
    static func noRequestLimit(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        let(s,_)=try session(f,p);try await s.start()
        for id in 1...20 {
            let lease=try request(s,UInt64(id));try require(s.readiness() != nil,"an active reservation lost readiness")
            try lease.start{_ in true};await lease.waitUntilRetired();lease.releaseResources()
        }
        try require(s.admissionState?.requestsServed==20 && s.readiness() != nil,"a session stopped being ready after many requests")
        try require(await s.drain(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000) == .released,"drain after many requests failed")
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
    /// No fixed lifetime: a session whose owners' leases are renewed outlives
    /// the first lease grant, here a session that serves on past the first
    /// renewal interval, then stops cleanly when asked.
    static func outlivesFirstGrant(_ f:InstalledFixture) async throws {
        let prepared=try f.prepare(),(s,box)=try session(f,prepared)
        try await s.start()
        try await Task.sleep(nanoseconds:ClusterWorkerLease.renewNanoseconds+1_500_000_000)
        try require(s.readiness() != nil && s.admissionState?.isValid==true,"a renewed session stopped being ready")
        let lease=try request(s,77);try lease.start{_ in true};await lease.waitUntilRetired();lease.releaseResources()
        let result=await s.stop(until:DispatchTime.now().uptimeNanoseconds+8_000_000_000)
        try require(result == .released,"a renewed session did not release on stop: \(result)")
        try require(box.snapshot.allSatisfy{$0.nativeCleanupObserved && $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)},"stop lacked owner release")
    }
    static func stopNotice(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        let notices=NoticeBox()
        let(quiet,_)=try session(f,p);quiet.installStopNoticeHandler{notices.add($0,running:[])};try await quiet.start()
        let lease=try request(quiet,1);try lease.start{_ in true};await lease.waitUntilRetired();lease.releaseResources()
        try require(await quiet.drain(until:DispatchTime.now().uptimeNanoseconds+5_000_000_000) == .released,"requested drain did not release")
        try await Task.sleep(for:.milliseconds(100))
        try require(notices.count==0,"a requested stop was announced as an unrequested one")
        // Rank 0 never commits a token, does not answer cancel and needs 1.5 s
        // to end after its stream closes: a rank inside a collective whose peer went away.
        let(s,box)=try session(f,p,behavior:"workers:stall,normal")
        s.installStopNoticeHandler{notices.add($0,running:box.snapshot.filter{!$0.nativeCleanupObserved}.map(\.rank))}
        try await s.start()
        let stalled=try request(s,2);try stalled.start{_ in true}
        try await Task.sleep(for:.milliseconds(100))
        let began=ContinuousClock.now
        stalled.cancel()
        while notices.count==0 && began.duration(to:.now) < .seconds(3) {try await Task.sleep(for:.milliseconds(10))}
        guard let notice=notices.first else {throw CheckFailure(message:"no stop notice for a session that stopped unasked")}
        try require(began.duration(to:notice.at) < .seconds(1),"the stop notice came late: \(began.duration(to:notice.at))")
        try require(notice.running.contains(0),"the stop notice came only after the surviving rank had ended: \(notice.running)")
        try require(notice.value.longestWaitNanoseconds==75_000_000_000 && notice.value.progressLimitMilliseconds==60_000,"the notice's wait is not the progress limit plus the stop margin")
        try require(notice.value.message.contains("75 s") && notice.value.message.contains("60 s progress limit"),"the notice does not state the wait")
        await stalled.waitUntilRetired();stalled.releaseResources()
        let result=await s.stop(until:DispatchTime.now().uptimeNanoseconds+8_000_000_000)
        try require((result == .released || result == .quarantined) && s.readiness()==nil && box.snapshot.allSatisfy(\.nativeCleanupObserved),"the unasked stop did not end both ranks: \(result)")
        try require(notices.count==1,"the stop was announced more than once")
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
