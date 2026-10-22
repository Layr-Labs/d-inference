import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
import MLXLMCommon
@testable import InstalledContract

struct CheckFailure: Error { let message:String }
func require(_ value:Bool,_ message:String) throws { if !value { throw CheckFailure(message:message) } }
func require<T>(_ value:T?,_ message:String) throws->T { guard let value else { throw CheckFailure(message:message) }; return value }
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
            case .token(let token), .loggedToken(let token, _): tokens.append((token,time))
            case .finished(let reason): finish=time; if case .error = reason { failure=true }
            case .promptCache, .telemetry: break
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
    /// The installed launch arguments with the combined profile's attachment,
    /// which always comes last, checked and removed.
    static func withoutBootstrap(_ plan:DistributedInstalledPlan,binding:ClusterOwnerBinding,deadline:UInt64) throws->[String] {
        let start=try DistributedInstalledNativeStart.starts(plan:plan,epoch:binding.identity.membershipEpoch)[binding.rank]
        let attachment=try ClusterOwnerBootstrapAttachment(profile:.nativeKeyPreludeMesh2,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000,nativeStart:start)
        defer{attachment.cancel()}
        let arguments=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:attachment)
        try require(Array(arguments.suffix(attachment.workerArguments.count))==attachment.workerArguments,"bootstrap arguments are not last")
        return Array(arguments.dropLast(attachment.workerArguments.count))
    }
    /// The link the pair's last load measured: kept per pair (either order),
    /// read back as the planner's link costs, never another pair's, never stale.
    static func linkProbeHistory() throws {
        let probeHome = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("link-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probeHome) }
        for path in ["", ".darkbloom", ".darkbloom/cluster"] {
            try FileManager.default.createDirectory(at: probeHome.appendingPathComponent(path), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 20,
            pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 1_100, allSumSmallBytes: 20_480, allSumSmallMicroseconds: 33,
            allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 2_100)
        try require(ClusterLinkProbeHistory.costs(homeDirectory: probeHome, members: ["a", "b"]) == nil, "No probe: no link costs")
        try require(ClusterLinkProbeHistory.record(probe, members: ["b", "a"], homeDirectory: probeHome, now: 1_000), "Probe not kept")
        let costs = ClusterLinkProbeHistory.costs(homeDirectory: probeHome, members: ["a", "b"], now: 2_000)
        try require(costs?.measured == true && costs?.reduction?.keyed == true
            && abs((costs?.reduction?.seconds(bytes: 20_480) ?? 0) - 33e-6) < 1e-9, "Probe costs not read back for the pair in either order")
        try require(ClusterLinkProbeHistory.costs(homeDirectory: probeHome, members: ["a", "c"], now: 2_000) == nil, "Another pair read this pair's probe")
        try require(ClusterLinkProbeHistory.costs(homeDirectory: probeHome, members: ["a", "b"],
            now: 1_000 + ClusterLinkProbeHistory.maximumAgeSeconds + 1) == nil, "A stale probe was used")
    }
    /// A served tensor-parallel request names its setup as the planner reads
    /// it back: every rank 0-<layers> (not the capability plan's stage cut the
    /// shards were read through), with each rank's weight when the shares are
    /// unequal, so the calibration credits it to the split it ran.
    static func tensorParallelSessionCut() throws {
        let stages = [(rank: 1, start: 16, end: 64), (rank: 0, start: 0, end: 16)]
        try require(DistributedSessionFacts.cut(stages)=="0-16|16-64","pipeline cut changed")
        try require(DistributedSessionFacts.cut(stages,mode:.pipelineCompactDecode,tensorShares:[1,3])=="0-16|16-64","pipeline cut took shares")
        let equal=DistributedSessionFacts.cut(stages,mode:.tensorParallel,tensorShares:nil)
        let weighted=DistributedSessionFacts.cut(stages,mode:.tensorParallel,tensorShares:[1,3])
        try require(equal=="0-64|0-64" && ClusterServedSpeedRecords.Setup.cuts(equal,layerCount:64,mode:.tensorParallel,ranks:2)==[],
            "equal tensor-parallel session cut is \(equal)")
        try require(weighted=="0-64@1|0-64@3" && ClusterServedSpeedRecords.Setup.cuts(weighted,layerCount:64,mode:.tensorParallel,ranks:2)==[]
            && ClusterServedSpeedRecords.Setup.tensorShares(weighted)==[1,3], "weighted tensor-parallel session cut is \(weighted)")
    }
    /// `darkbloom cluster local` (2026-10-15): the leader part's start for each scope, the service's part key (a scope
    /// change restarts rank 0, public keeps the earlier key), the log line that says how the CURRENT run serves, and
    /// the scope on the wire (an older build's message carries none). Failing first on 69ba75be7 (no such API).
    static func localOnlyServing() throws {
        let base=["start","--local","--distributed"]
        try require(ClusterLocalServing.leaderArguments(base,scope:.publicServing)==base,"public start changed")
        try require(ClusterLocalServing.leaderArguments(base,scope:.localOnly(bind:"0.0.0.0"))==base+["--no-coordinator","--bind","0.0.0.0"],
            "local-only start does not skip the coordinator on every interface")
        try require(ClusterLocalServing.soloArguments(["start","--local"],scope:.localOnly(bind:"::1"))==["start","--local","--bind","::1"],
            "local-only solo server not on the chosen address")
        try require(ClusterLocalServing.soloArguments(["start","--local"],scope:.publicServing)==["start","--local"],"public solo server changed")
        let sha=String(repeating:"a",count:64)
        let publicKey=ClusterLocalServing.partKey(setupSHA256:sha,scope:.publicServing)
        let localKey=ClusterLocalServing.partKey(setupSHA256:sha,scope:.localOnly(bind:"0.0.0.0"))
        try require(publicKey=="cluster:"+sha,"public part key changed (a running part would restart on upgrade)")
        try require(localKey != publicKey && ClusterLocalServing.scopeChangedOnly(from:publicKey,to:localKey)
            && ClusterLocalServing.scopeChangedOnly(from:localKey,to:ClusterLocalServing.partKey(setupSHA256:sha,scope:.localOnly(bind:"::1"))),
            "a scope change is not seen as one")
        try require(!ClusterLocalServing.scopeChangedOnly(from:publicKey,to:"cluster:"+String(repeating:"b",count:64)+":local-only@0.0.0.0")
            && !ClusterLocalServing.scopeChangedOnly(from:publicKey,to:publicKey) && !ClusterLocalServing.scopeChangedOnly(from:"solo:m",to:publicKey)
            && !ClusterLocalServing.scopeChangedOnly(from:nil,to:publicKey),"a new setup, the same key or a solo server read as a scope change")
        let banner="darkbloom 0.9.20 (local / distributed)"
        try require(ClusterLocalServing.notice(inLog:"\(banner)\n\(ClusterLocalServing.localOnlyLogLine)\nListening on 0.0.0.0:8000\n")
            == ClusterLocalServing.localOnlyNotice,"local-only run not read from its log line")
        try require(ClusterLocalServing.notice(inLog:"\(ClusterLocalServing.localOnlyLogLine)\n\(ClusterLocalServing.registeredLogLine)\n")==nil,
            "an earlier local-only run read as the current one")
        try require(ClusterLocalServing.notice(inLog:"\(ClusterLocalServing.registeredLogLine)\n\(ClusterLocalServing.logLine)\n") == ClusterLocalServing.notice,
            "the fallback line changed")
        try require(ClusterLocalServing.localOnlyNotice.contains("this Mac's API") && !ClusterLocalServing.localOnlyNotice.contains("\n"),
            "the local-only line is not worded for the screen's this/that Mac rewrite")
        try require(ClusterLocalServing.noCoordinatorFlag=="--no-coordinator","start flag name differs from `darkbloom start`")

        let local=ClusterServiceCommand(op:.serve,model:"m",scope:.localOnly(bind:"0.0.0.0"))
        let decoded=try JSONDecoder().decode(ClusterServiceCommand.self,from:JSONEncoder().encode(local))
        try require(decoded.scope == .localOnly(bind:"0.0.0.0"),"the start does not carry the local-only scope")
        let older=try JSONDecoder().decode(ClusterServiceCommand.self,from:Data(#"{"op":"serve","model":"m"}"#.utf8))
        try require(older.scope==nil,"an older leader's start read as a scope")
        let tampered=try JSONDecoder().decode(ClusterServiceCommand.self,from:Data(#"{"op":"serve","localOnly":true,"bind":"0.0.0.0 --no-auth"}"#.utf8))
        try require(tampered.scope==nil,"a start with an address the API does not take was accepted")
        let publicStart=try JSONDecoder().decode(ClusterServiceCommand.self,from:JSONEncoder().encode(ClusterServiceCommand(op:.serve,scope:.publicServing)))
        try require(publicStart.scope == .publicServing,"the public scope is not carried")
        let request=try JSONDecoder().decode(ClusterControlRequest.self,from:JSONEncoder().encode(ClusterControlRequest(op:.scope,scope:.localOnly(bind:"::1"))))
        try require(request.op == .scope && request.scope == .localOnly(bind:"::1"),"the forwarded scope request does not round-trip")
        let status=try JSONDecoder().decode(ClusterServiceStatus.self,from:Data(#"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1}}"#.utf8))
        try require(status.localOnly==nil,"an older member's status read as a scope")

        // The API's port (2026-10-15: oMLX held 8000 on the M5 Max; every start ended after its load). A real listener
        // on a port makes it taken; the leading part takes the next free one.
        let listener=socket(AF_INET,SOCK_STREAM,0)
        defer{close(listener)}
        var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family=sa_family_t(AF_INET)
        address.sin_port=0; address.sin_addr=in_addr(s_addr:INADDR_ANY.bigEndian)
        _=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        try require(listen(listener,1)==0,"test listener did not listen")
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(listener,$0,&length)}}
        let taken=Int(UInt16(bigEndian:address.sin_port))
        try require(!ClusterLocalServing.portIsFree(taken),"a port another program listens on read as free")
        try require(!ClusterLocalServing.portIsFree(0) && !ClusterLocalServing.portIsFree(70_000),"an impossible port read as free")
        try require(ClusterLocalServing.servingPort(isFree:{_ in true})==8000,"8000 not kept when free")
        try require(ClusterLocalServing.servingPort(isFree:{$0 != 8000 && $0 != 8001})==8002,"the next free port not taken")
        try require(ClusterLocalServing.servingPort(isFree:{_ in false})==8000,"no free port: 8000 (the start then says it is taken)")

        // One port on both Macs (2026-10-16: oMLX on the M5 Max's 8000 put the API on 8000 or 8001 by which Mac was rank 0).
        let all=Array(ClusterLocalServing.servingPorts)
        let no8000=all.filter{$0 != 8000}
        try require(ClusterLocalServing.freePorts(isFree:{$0 != 8000 && $0 != 8005})==all.filter{$0 != 8000 && $0 != 8005},"free ports misread")
        try require(ClusterLocalServing.freePorts(isFree:{_ in false}).isEmpty && all.first==8000 && all.last==8020,"the serving ports are not 8000 to 8020")
        try require(ClusterLocalServing.sharedPort(localFree:all,peerFree:all)==8000,"8000 not taken when free on both")
        try require(ClusterLocalServing.sharedPort(localFree:all,peerFree:no8000)==8001,"8000 taken on the other Mac: not 8001 here")
        try require(ClusterLocalServing.sharedPort(localFree:no8000,peerFree:all)==8001,"8000 taken here: not 8001")
        try require(ClusterLocalServing.sharedPort(localFree:all.filter{$0 != 8001},peerFree:no8000)==8002,"not the lowest port free on both")
        try require(ClusterLocalServing.sharedPort(localFree:all,peerFree:all,preferred:8001)==8001,"a port free on both not kept")
        try require(ClusterLocalServing.sharedPort(localFree:all,peerFree:all.filter{$0 != 8001},preferred:8001)==8000,"a kept port taken on the other Mac not left")
        try require(ClusterLocalServing.sharedPort(localFree:no8000,peerFree:nil)==8001,"an older Mac's status: not this Mac's own choice")
        try require(ClusterLocalServing.sharedPort(localFree:all,peerFree:nil,preferred:8003)==8003,"an older Mac's status: the kept port not kept")
        try require(ClusterLocalServing.sharedPort(localFree:[8000],peerFree:[8001])==8000,"nothing free on both: not this Mac's own choice")
        try require(ClusterLocalServing.sharedPort(localFree:no8000,peerFree:[],preferred:8000)==8001,"nothing free on the other Mac: a port taken here")
        try require(ClusterLocalServing.sharedPort(localFree:[],peerFree:all)==8000,"nothing free here: not 8000")
        var withPorts=status; withPorts.freePorts=[8001,8002]
        let decodedPorts=try JSONDecoder().decode(ClusterServiceStatus.self,from:JSONEncoder().encode(withPorts)).freePorts
        try require(decodedPorts==[8001,8002],"free ports do not round-trip")
        try require(status.freePorts==nil,"an older Mac's status read as free ports")

        // The relay on the Mac that is not rank 0 (2026-10-16): bytes pass both ways, the reply ends when the API
        // closes, and a stopped relay gives its port back.
        let api=socket(AF_INET,SOCK_STREAM,0)
        defer{close(api)}
        var apiAddress=sockaddr_in(); apiAddress.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); apiAddress.sin_family=sa_family_t(AF_INET)
        apiAddress.sin_port=0; apiAddress.sin_addr=in_addr(s_addr:INADDR_LOOPBACK.bigEndian)
        _=withUnsafePointer(to:&apiAddress){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(api,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        try require(listen(api,4)==0,"stand-in API did not listen")
        var apiLength=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&apiAddress){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(api,$0,&apiLength)}}
        let apiPort=Int(UInt16(bigEndian:apiAddress.sin_port))
        Thread.detachNewThread {
            let connection=accept(api,nil,nil); guard connection>=0 else{return}
            var buffer=[UInt8](repeating:0,count:64); let count=read(connection,&buffer,64)
            if count>0 { let reply=Array("echo:".utf8)+buffer[0..<count]; _=reply.withUnsafeBytes{write(connection,$0.baseAddress,$0.count)} }
            close(connection)
        }
        let relayPort=ClusterLocalServing.servingPort(preferred:47_000+Int(getpid()%1_000),span:200)
        guard let relay=ClusterLocalRelay(port:relayPort,bind:"127.0.0.1",target:.init(host:"127.0.0.1",port:apiPort)) else{throw CheckFailure(message:"relay did not listen on \(relayPort)")}
        try require(!ClusterLocalServing.portIsFree(relayPort),"the relay's port read as free")
        guard let client=ClusterLocalRelay.connect(.init(host:"127.0.0.1",port:relayPort)) else{throw CheckFailure(message:"could not reach the relay")}
        defer{close(client)}
        _=Array("hello".utf8).withUnsafeBytes{write(client,$0.baseAddress,$0.count)}
        var received=[UInt8](); var chunk=[UInt8](repeating:0,count:64)
        while true { let count=read(client,&chunk,64); if count<=0{break}; received+=chunk[0..<count] }
        try require(String(decoding:received,as:UTF8.self)=="echo:hello","relay passed \(String(decoding:received,as:UTF8.self))")
        relay.stop()
        try require(relay.isStopped && ClusterLocalServing.portIsFree(relayPort),"a stopped relay kept its port")
    }
    static func main() async throws {
        signal(SIGALRM){_ in Darwin._exit(124)};alarm(110);defer{alarm(0)}
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
        try linkProbeHistory()
        try tensorParallelSessionCut()
        try localOnlyServing()
        try prefixSSDKeyNeverInChildEnvironment(prepared)
        try pairedSetupRefusesLocalSession(fixture)
        try developerSSHGate(fixture)
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
        try await followerRefusalNamed(fixture,prepared)
        try await missingRelease(fixture,prepared)
        try await outlivesFirstGrant(fixture)
        try await stopNotice(fixture,prepared)
        try await stopBoundAfterGracefulThenUnrequested()
        print("Installed owner/session: metadata, bootstrap selection, progress guard, provider exclusion, generation mode, budgets derived from the setup, long prompts within them, owner serving with public grants from records, the developer-only SSH route, bounded IO and 9 lifecycle scenarios passed; no native model, SSH or network")
    }
    /// Round-4 finding 1: the prefix-SSD key never reaches a native rank's environment, which any process of
    /// the same user can read for the rank's whole life. A real child is started with exactly the environment
    /// the owner gives a native rank and prints it: neither key variable nor the key's bytes may appear.
    static func prefixSSDKeyNeverInChildEnvironment(_ prepared:DistributedInstalledPreparation) throws {
        let derived=Data((0..<32).map { UInt8(0xA0 ^ $0) })
        DistributedInstalledPrefixSSD.installDurableKeySource { derived }
        defer { DistributedInstalledPrefixSSD.installDurableKeySource { nil } }
        let hex=derived.map { String(format:"%02x",$0) }.joined()
        let environment=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:[:])
        let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/env");child.arguments=[];child.environment=environment
        let out=Pipe();child.standardOutput=out;try child.run()
        let printed=String(decoding:out.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);child.waitUntilExit()
        try require(child.terminationStatus==0 && printed.contains("JACCL_RANK=") && printed.contains("DARKBLOOM_CLUSTER_PREFIX_SSD_DIR="),
            "the child did not print the rank's environment")
        try require(!printed.contains("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") && !printed.lowercased().contains(hex)
            && !printed.contains(derived.base64EncodedString()),"the prefix-SSD key reached a native rank's environment")
        // The whole launch the owner builds: the key is in neither the arguments nor the environment; it is the
        // input's second line, after the data-plane credential, bound to this epoch and rank.
        let plan=prepared.plan
        let binding=try plan.binding(epoch:UUID(),lease:UUID(),incarnation:UUID())
        let epoch=binding.identity.membershipEpoch,deadline=DispatchTime.now().uptimeNanoseconds+100_000_000_000
        let starts=try DistributedInstalledNativeStart.starts(plan:plan,epoch:epoch)
        let attachment=try ClusterOwnerBootstrapAttachment(profile:.nativeKeyPreludeMesh2,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000,
            nativeStart:starts[plan.configuration.localRank])
        defer{attachment.cancel()}
        let trust=try ClusterDataPlaneLaunch.sessionCredentialLines(epoch:epoch)[plan.configuration.localRank]
        let sent=try require(plan.nativePrefixSSDKey(ownerEnvironment:[:]),"the tier is on, yet no key is sent")
        try require(sent==derived,"the key sent is not the owner's derived key")
        let launch=try DistributedInstalledOwner.nativeLaunch(prepared:prepared,binding:binding,deadline:deadline,startupDeadline:nil,
            attachment:attachment,dataPlaneTrust:trust,prefixSSDKey:sent,ownerEnvironment:[:])
        let joined=launch.arguments.joined(separator:" ")
        try require(Array(launch.arguments.suffix(12).prefix(4))==["--data-plane","encrypted_v1","--prefix-ssd-key",
            ClusterWorkerPrefixSSDKey.argument],"the launch does not announce the key on the input: \(launch.arguments)")
        try require(!joined.lowercased().contains(hex) && !joined.contains(derived.base64EncodedString())
            && !launch.environment.keys.contains(where:{ $0.hasPrefix("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") })
            && !launch.environment.values.contains(where:{ $0.lowercased().contains(hex) }),"the key reached the arguments or the environment")
        let lines=try require(launch.initialInput,"no initial input").split(separator:10,omittingEmptySubsequences:false)
        try require(lines.count==3 && lines[2].isEmpty && Data(lines[0])+Data([10])==trust,"the credential is not the input's first line")
        let line=try ClusterWorkerCodec.decodePrefixSSDKey(Data(lines[1])+Data([10]))
        try require(line.key==derived && line.membershipEpoch==epoch && line.rank==binding.rank,"the input's key line is not bound to this epoch and rank")
        try require(!String(describing:line).lowercased().contains(hex) && !String(reflecting:line).contains(derived.base64EncodedString()),
            "the key line's description shows the key")
        // The owner's worker process accepts the two lines; a third line, or an oversized one, is refused.
        func process(_ input:Data?) throws {
            _ = try ClusterWorkerProcess(launch:.init(executable:launch.executable,arguments:launch.arguments,environment:launch.environment,
                initialInput:input),expectedIdentity:binding.identity,rank:binding.rank,profile:binding.profile,
                executionPlanSHA256:binding.executionPlanSHA256,startupDeadline:deadline,initialLeaseDeadline:deadline)
        }
        try process(launch.initialInput)
        try rejected{try process(launch.initialInput!+launch.initialInput!)}
        try rejected{try process(Data(repeating:65,count:4096)+Data([10]))}
        // Tier off: no key, no argument, the credential alone.
        let plain=try DistributedInstalledOwner.nativeLaunch(prepared:prepared,binding:binding,deadline:deadline,startupDeadline:nil,
            attachment:attachment,dataPlaneTrust:trust,prefixSSDKey:nil,ownerEnvironment:[:])
        try require(!plain.arguments.contains("--prefix-ssd-key") && plain.initialInput==trust,"a launch without the tier carries a key")
    }
    static func changedConfiguration(_ f:InstalledFixture,edit:(inout [String:Any])->Void) throws->ClusterConfiguration {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.configuration)) as! [String:Any];edit(&object)
        return try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:object),capability:f.capability,capabilitySHA256:f.configuration.capabilitySHA256)
    }
    /// No SSH in the user path: a setup that reaches the follower over SSH is
    /// refused before anything starts unless the developer flag is set; a
    /// link control setup is never refused for its route.
    static func developerSSHGate(_ f:InstalledFixture) throws {
        try require(f.configuration.trust != nil && f.configuration.linkControl == nil,"fixture is not an SSH setup")
        var message=""
        do { try DistributedInstalledDeveloperSSH.requireFollowerRoute(f.configuration,environment:[:]) } catch { message=String(describing:error) }
        try require(message.contains("over SSH") && message.contains("Run `darkbloom cluster` on both Macs") && !message.contains("cluster setup") && !message.contains(DistributedInstalledDeveloperSSH.environmentKey),
            "an SSH setup was not refused without the developer flag (or the refusal offers the flag): \(message)")
        try rejected{ try DistributedInstalledDeveloperSSH.requireFollowerRoute(f.configuration,environment:[DistributedInstalledDeveloperSSH.environmentKey:"yes"]) }
        try DistributedInstalledDeveloperSSH.requireFollowerRoute(f.configuration,environment:[DistributedInstalledDeveloperSSH.environmentKey:"1"])
        let link=try changedConfiguration(f){ object in
            object["trust"]=nil
            object["linkControl"]=["schema":"darkbloom_cluster_link_control_v1","port":47999,"linkEpoch":UUID().uuidString.lowercased(),
                                   "edgeID":UUID().uuidString.lowercased(),"secretFile":f.root.appendingPathComponent("link-secret").path]
        }
        try require(link.linkControl != nil && link.trust == nil,"link fixture differs")
        try DistributedInstalledDeveloperSSH.requireFollowerRoute(link,environment:[:])
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
        let environment=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:[:])
        try require(environment.count==13 && environment["JACCL_RANK"]=="0" && environment["MLX_ENABLE_TF32"]=="1"
            && environment["DARKBLOOM_CLUSTER_PREFIX_SSD_STOP_MARGIN_MS"]==String(prepared.plan.budgets.stopMarginNanoseconds/1_000_000)
            && environment["MLX_MAX_OPS_PER_BUFFER"]=="16" && environment["MLX_MAX_MB_PER_BUFFER"]==nil,"native environment widened")
        // The prefix cache's SSD tier: on by default, under this user's caches, with this Mac's durable owner key:
        // without the product's key source, an owner-only key file made once and never replaced. The rank gets the
        // directory in its environment and the key's bytes only on its input (`nativePrefixSSDKey`).
        let keyFile=prepared.plan.paths.deviceDirectory.appendingPathComponent("prefix-ssd-v1.key")
        let sentKey=prepared.plan.nativePrefixSSDKey(ownerEnvironment:[:])
        try require(environment["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"]==prepared.plan.paths.homeDirectory
            .appendingPathComponent("Library/Caches/darkbloom/cluster-prefix-v1",isDirectory:true).path
            && !environment.keys.contains(where:{ $0.hasPrefix("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") }),"prefix SSD tier not configured")
        var keyInfo=stat()
        let keyText=try Data(contentsOf:keyFile)
        try require(lstat(keyFile.path,&keyInfo)==0 && keyInfo.st_mode & S_IFMT==S_IFREG && keyInfo.st_mode & 0o077==0
            && keyInfo.st_uid==getuid() && keyText.count==65 && DistributedInstalledPrefixSSD.isKeyText(keyText),
            "prefix SSD key file is not an owner-only 64-hex key")
        try require(sentKey != nil && sentKey==DistributedInstalledPrefixSSD.decodeKeyText(keyText),"the rank's key is not the key file's")
        try require(prepared.plan.nativePrefixSSDKey(ownerEnvironment:[:])==sentKey,"one owner, one SSD key")
        // A later owner process (nothing cached) reads the same file, never a new key.
        let device=prepared.plan.paths.deviceDirectory
        let laterFile=DistributedInstalledPrefixSSD.keyFile(deviceDirectory:device),laterText=try Data(contentsOf:keyFile)
        try require(laterFile==keyFile && laterText==keyText,"a later owner must keep the same SSD key")
        // A file that is not an owner-only key is never replaced and never used.
        let otherDevice=device.deletingLastPathComponent().appendingPathComponent("cluster-device-check",isDirectory:true)
        try FileManager.default.createDirectory(at:otherDevice,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:otherDevice) }
        let bad=otherDevice.appendingPathComponent("prefix-ssd-v1.key")
        try Data("not a key\n".utf8).write(to:bad);chmod(bad.path,0o600)
        let badFile=DistributedInstalledPrefixSSD.keyFile(deviceDirectory:otherDevice),badText=try Data(contentsOf:bad)
        try require(badFile==nil && badText==Data("not a key\n".utf8),"an unusable key file must be left alone")
        // The product's key source, when installed and loading, wins: its bytes go to the rank's input, no file.
        let derived=Data((0..<32).map { UInt8($0) })
        DistributedInstalledPrefixSSD.installDurableKeySource { derived }
        try require(DistributedInstalledPrefixSSD.ownerKey(deviceDirectory:otherDevice) == .derived(derived)
            && DistributedInstalledPrefixSSD.key(home:prepared.plan.paths.homeDirectory,deviceDirectory:otherDevice,
                ownerEnvironment:[:],prefixCacheOff:false)==derived,"product key source not preferred")
        try require(!DistributedInstalledPrefixSSD.environment(home:prepared.plan.paths.homeDirectory,deviceDirectory:otherDevice,
            ownerEnvironment:[:],prefixCacheOff:false).keys.contains(where:{ $0.hasPrefix("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") }),
            "the derived SSD key must not be in the environment")
        try require(!String(describing:DistributedInstalledPrefixSSD.ownerKey(deviceDirectory:otherDevice)).contains("0001020304"),
            "an owner key's description must redact it")
        DistributedInstalledPrefixSSD.installDurableKeySource { nil }
        try require(DistributedInstalledPrefixSSD.ownerKey(deviceDirectory:device) == .file(keyFile,sentKey!),
            "an unavailable product key must fall back to the key file")
        try require(DistributedInstalledPrefixSSD.ownerKey(deviceDirectory:otherDevice)
            == .process(DistributedInstalledPrefixSSD.processKey),"no usable key file: this owner's own key")
        let ssdOff=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_SSD":"off"])
        try require(ssdOff["DARKBLOOM_CLUSTER_PREFIX_SSD"]=="off"
            && !ssdOff.keys.contains(where:{ $0.hasPrefix("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") })
            && ssdOff["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"] != nil,"prefix SSD off switch not passed")
        try require(prepared.plan.nativePrefixSSDKey(ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_SSD":"off"])==nil,
            "the SSD tier switched off must send no key")
        let cacheOff=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_CACHE":"off",
            "DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB":"4"])
        try require(cacheOff.count==12 && cacheOff["DARKBLOOM_CLUSTER_PREFIX_CACHE"]=="off" && cacheOff["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"]==nil,
            "prefix cache off must not configure the SSD tier")
        try require(prepared.plan.nativePrefixSSDKey(ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_CACHE":"off"])==nil,
            "prefix cache off must send no SSD key")
        let tuned=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB":"4",
            "DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS":"x"])
        try require(tuned["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB"]=="4" && tuned["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS"]==nil,
            "prefix SSD budget switches not passed through or not bounded")
        // ALIGN with the product's caching system: the owner installs the product's resolved settings (the saved cache
        // directory, gate, budget rule, daily write cap and TTL the single-Mac tier reads); the rank's root and
        // switches follow them, and the cluster-only switches remain diagnosis overrides.
        let pinnedBase=prepared.plan.paths.homeDirectory.appendingPathComponent("pinned-volume",isDirectory:true)
        var product=ClusterPrefixCacheSettings(root:ClusterPrefixCacheSettings.root(cacheBase:pinnedBase),prefixCacheEnabled:true,
            byteBudget:40*1_073_741_824+5,dailyWriteBytes:120_000_000_000,ttlSeconds:900)
        try require(product.root.path==pinnedBase.path+"/darkbloom/cluster-prefix-v1","cluster root is not beside the product's kv3 tier")
        try require(ClusterPrefixCacheSettings.builtIn(home:prepared.plan.paths.homeDirectory).root.path==prepared.plan.paths.homeDirectory
            .appendingPathComponent("Library/Caches/darkbloom/cluster-prefix-v1",isDirectory:true).path,"built-in root moved")
        DistributedInstalledPrefixSSD.installProductSettings(product)
        defer { DistributedInstalledPrefixSSD.installProductSettings(nil) }
        let aligned=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:[:])
        try require(aligned["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"]==product.root.path
            && aligned["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB"]=="40" && aligned["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_WRITE_GB_PER_DAY"]=="120"
            && aligned["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS"]=="900"
            && !aligned.keys.contains(where:{ $0.hasPrefix("DARKBLOOM_CLUSTER_PREFIX_SSD_KEY") })
            && prepared.plan.nativePrefixSSDKey(ownerEnvironment:[:])==sentKey,
            "rank environment does not follow the product's cache settings")
        // An unlimited daily cap is 0; a budget below one GiB is one; a TTL above the ceiling is the ceiling; a diagnosis
        // override in the owner's environment still wins.
        product.byteBudget=5;product.dailyWriteBytes=0;product.ttlSeconds=9_999
        DistributedInstalledPrefixSSD.installProductSettings(product)
        let bounded=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB":"2"])
        try require(bounded["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_GB"]=="2" && bounded["DARKBLOOM_CLUSTER_PREFIX_SSD_MAX_WRITE_GB_PER_DAY"]=="0"
            && bounded["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_SECONDS"]=="1800","product settings not bounded or override lost")
        // The product's gate off: the pair's prefix cache is off and no SSD tier is configured.
        product.prefixCacheEnabled=false
        DistributedInstalledPrefixSSD.installProductSettings(product)
        let gated=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL,ownerEnvironment:[:])
        try require(gated["DARKBLOOM_CLUSTER_PREFIX_CACHE"]=="off" && gated["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"]==nil
            && prepared.plan.nativePrefixSSDKey(ownerEnvironment:[:])==nil,"the product's prefix cache gate must turn the pair's cache off")
        // The leader's sync: the member keeps its own root, takes the leader's gate, cap, budget and TTL; an unknown
        // version or an out-of-range value is refused and the member keeps its own.
        product.prefixCacheEnabled=true;product.byteBudget=nil;product.dailyWriteBytes=nil;product.ttlSeconds=nil
        let leader=ClusterPrefixCacheSettings(root:URL(fileURLWithPath:"/leader/root"),prefixCacheEnabled:true,
            byteBudget:8*1_073_741_824,dailyWriteBytes:50_000_000_000,ttlSeconds:600)
        let sync=ClusterCacheSettingsSync(leader:leader)
        let applied=try ClusterCacheSettingsSync.decode(try sync.encoded()).applied(to:product)
        try require(applied.root==product.root && applied.byteBudget==8*1_073_741_824 && applied.dailyWriteBytes==50_000_000_000
            && applied.ttlSeconds==600 && applied.prefixCacheEnabled,"leader sync not applied to the member")
        var stale=sync;stale.version=2
        try require((try? stale.applied(to:product))==nil,"an unknown sync version must be refused")
        var wide=sync;wide.ttlSeconds=3_600
        try require((try? wide.applied(to:product))==nil,"an out-of-range synced TTL must be refused")
        try require((try? ClusterCacheSettingsSync.decode(Data(repeating:0x20,count:5_000)))==nil,"an oversized sync must be refused")
        // Inspection and reclaim read and remove only the tier's own names; a live rank's plan is kept.
        let tierRoot=prepared.plan.paths.homeDirectory.appendingPathComponent("tier-root",isDirectory:true)
        let planA=tierRoot.appendingPathComponent("v1-"+String(repeating:"ab",count:12),isDirectory:true)
        let planB=tierRoot.appendingPathComponent("v1-"+String(repeating:"cd",count:12),isDirectory:true)
        for directory in [planA.appendingPathComponent("rank0"),planA.appendingPathComponent("rank1"),planB.appendingPathComponent("rank0"),
            tierRoot.appendingPathComponent("not-ours")] {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        }
        try Data(repeating:1,count:1000).write(to:planA.appendingPathComponent("rank0/"+String(repeating:"0",count:32)+".dbpx"))
        try Data(repeating:1,count:500).write(to:planA.appendingPathComponent("rank1/"+String(repeating:"1",count:32)+".dbpx"))
        try Data(repeating:1,count:10).write(to:planA.appendingPathComponent("rank1/.tmp.dbpx"))
        try Data(repeating:1,count:7).write(to:planB.appendingPathComponent("rank0/"+String(repeating:"2",count:32)+".dbpx"))
        // The rank stages records under <root>/staging/<membership epoch>; the reaper removes a dead epoch's only.
        let stagingRoot=ClusterPrefixCacheSettings.stagingRoot(root:tierRoot)
        let deadEpoch=UUID().uuidString.lowercased(), liveEpoch=UUID().uuidString.lowercased()
        for epoch in [deadEpoch,liveEpoch] {
            try FileManager.default.createDirectory(at:stagingRoot.appendingPathComponent(epoch),withIntermediateDirectories:true)
        }
        try Data(repeating:1,count:3).write(to:stagingRoot.appendingPathComponent(deadEpoch+"/.half.1.tmp"))
        let staleStaging=ClusterOrphanReaper.staleStagingEntries(roots:[stagingRoot],liveEpochs:[liveEpoch],graceSeconds:0)
        try require(staleStaging.map{$0.lastPathComponent}==[deadEpoch],"the reaper must name only the dead epoch's staging directory")
        let inspected=ClusterPrefixSSDInspection.inspect(root:tierRoot)
        try require(inspected.present && inspected.plans==2 && inspected.records==3 && inspected.bytes==1507 && inspected.ranks.count==3
            && inspected.line.hasPrefix("Cluster prefix tier: 2 plans, 3 records, 0.00 GB"),"cluster tier inspection miscounts")
        try require(!ClusterPrefixSSDInspection.inspect(root:tierRoot.appendingPathComponent("absent")).present,"an absent root must read as none")
        let inUse=planB.appendingPathComponent("in-use")
        try Data().write(to:inUse)
        let held=open(inUse.path,O_RDONLY)
        try require(held>=0 && flock(held,LOCK_EX|LOCK_NB)==0,"could not hold the live plan")
        let reclaimed=ClusterPrefixSSDReclaim.reclaim(root:tierRoot)
        try require(reclaimed.removedPlans==1 && reclaimed.keptLive==1 && !reclaimed.rootRemoved && reclaimed.problems.isEmpty
            && !FileManager.default.fileExists(atPath:planA.path) && FileManager.default.fileExists(atPath:planB.path)
            && FileManager.default.fileExists(atPath:tierRoot.appendingPathComponent("not-ours").path),"reclaim removed the wrong plans")
        try require(FileManager.default.fileExists(atPath:stagingRoot.path),"reclaim must keep the staging root while a rank is live")
        close(held)
        let laterReclaim=ClusterPrefixSSDReclaim.reclaim(root:tierRoot)
        try require(laterReclaim.removedPlans==1 && laterReclaim.keptLive==0 && !laterReclaim.rootRemoved,"a released plan must be reclaimed next time")
        try require(!FileManager.default.fileExists(atPath:stagingRoot.path),"with no live rank the staging root is reclaimed too")
        try require(environment["JACCL_PROGRESS_TIMEOUT_MS"]=="60000","installed plan did not set the collective progress limit")
        let local=try ClusterLocalOwnerConfiguration(installedDarkbloom:f.owner).launch()
        try require(local.arguments==["cluster","worker-owner","--stdio"] && local.environment.count==3,"local owner command widened")
        try rejected{_ = try ClusterLocalOwnerConfiguration(installedDarkbloom:URL(fileURLWithPath:"/unsafe/../owner"))}
    }
    /// The installed build starts its ranks with the owner-authenticated
    /// bootstrap (S07): the native key prelude, then the mesh rounds, through
    /// both owners and the leader's relay. A launch without its attachment, or
    /// with another profile's, is a mismatch, never a silent downgrade.
    static func bootstrapSelection(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        let plan=prepared.plan
        try require(plan.bootstrap == .ownerAuthenticated && plan.bootstrap.ownerProfile == .nativeKeyPreludeMesh2 && plan.bootstrap.ownerAuthenticated,"installed bootstrap selection differs")
        let binding=try plan.binding(epoch:UUID(),lease:UUID(),incarnation:UUID())
        let deadline=DispatchTime.now().uptimeNanoseconds+100_000_000_000
        let starts=try DistributedInstalledNativeStart.starts(plan:plan,epoch:binding.identity.membershipEpoch)
        try require(starts.count==2 && starts.map(\.rank)==[0,1] && starts[0].common.canonicalBytes==starts[1].common.canonicalBytes,"native starts differ")
        // Each owner admits only the start its own setup derives, for its own rank.
        let authorize=DistributedInstalledNativeStart.authorizer(plan:plan)
        try authorize(starts[plan.configuration.localRank])
        try rejected{try authorize(starts[1-plan.configuration.localRank])}
        let attachment=try ClusterOwnerBootstrapAttachment(profile:.nativeKeyPreludeMesh2,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000,
            nativeStart:starts[plan.configuration.localRank])
        defer{attachment.cancel()}
        try require(attachment.workerArguments.count==8 && attachment.workerArguments[0]=="--bootstrap-socket-path"
            && attachment.workerArguments[6]=="--native-authorization-start-base64","authenticated argument contract changed")
        let launched=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:deadline-1,attachment:attachment)
        try require(Array(launched.suffix(10).prefix(2))==["--startup-deadline-uptime-nanoseconds",String(deadline-1)]
            && Array(launched.suffix(8))==attachment.workerArguments,"startup deadline or bootstrap arguments were not passed to the worker")
        let legacy=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:attachment)
        try require(legacy.count==24+8,"a worker without the startup argument must be started without it")
        // S16: a worker whose owner received its data-plane credential is told so;
        // the credential itself is its first input line, never an argument.
        let keyed=try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:attachment,dataPlane:true)
        try require(keyed==Array(legacy.dropLast(8))+["--data-plane","encrypted_v1"]+attachment.workerArguments,"a keyed launch must add exactly the data-plane argument")
        // A startup may outlast the first lease grant (the lease is renewed
        // during the load), but not the protocol's hour; a first grant is at
        // most one lease grant away.
        _ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:deadline+1,attachment:attachment)
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:DispatchTime.now().uptimeNanoseconds+3_601_000_000_000,attachment:attachment)}
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:DispatchTime.now().uptimeNanoseconds+121_000_000_000,startupDeadline:nil,attachment:attachment)}
        // No attachment, or the mesh-only profile's: a mismatch.
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:nil)}
        let meshOnly=try ClusterOwnerBootstrapAttachment(profile:.mesh2,deadline:DispatchTime.now().uptimeNanoseconds+1_000_000_000)
        defer{meshOnly.cancel()}
        try rejected{_ = try plan.nativeArguments(binding:binding,deadline:deadline,startupDeadline:nil,attachment:meshOnly)}
        let (session,_)=try session(f,prepared)
        let observed=session.diagnosticObservation
        try require(observed.nativeBootstrap == .ownerAuthenticated && observed.nativeBootstrapOwnerAuthenticated,"status did not report the authenticated bootstrap")
        try require(observed.collectiveProgressLimitMilliseconds==60_000,"status omitted the collective progress limit")
        try require(observed.encryptedDataPlane==nil && observed.peerVerified==nil,"status observed a data plane before both ranks were ready")
        try require(session.cooperativeStopAllowanceNanoseconds==85_000_000_000,"stop allowance does not cover the clean-stop wait and the progress limit")
    }
    /// A pin names whatever binary was installed. The installed path also
    /// requires that binary to carry the collective progress guard.
    static func progressGuardIsRequired(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation,unguarded:URL) throws {
        try require(prepared.validation.workerFeatures == .init(hasProgressGuard:true,acceptsStartupDeadline:true,acceptsPrefixSSDKeyInput:true),
            "guarded worker features were not read from its bytes")
        let bare=try InstalledFixture.make(root:f.root.appendingPathComponent("unguarded"),probe:unguarded,owner:f.owner,worker:f.worker)
        var refusal=""
        do { _ = try bare.prepare() } catch { refusal=String(describing:error) }
        try require(refusal.contains("no collective progress guard"),"a worker without the progress guard was accepted: \(refusal)")
        // The same refusal reaches `cluster doctor` and the owner, which share this validation.
        try rejected{_ = try DistributedInstalledValidation.validate(reference:bare.reference,paths:bare.paths,deadline:DispatchTime.now().uptimeNanoseconds+5_000_000_000)}
        try rejected{try DistributedInstalledWorkerFeatures(hasProgressGuard:false,acceptsStartupDeadline:true).requireProgressGuard()}
        // A worker that cannot take the prefix-SSD key on its input is refused while the tier is on (never given
        // the key in its environment instead), and accepted with the tier off.
        let older=DistributedInstalledWorkerFeatures(hasProgressGuard:true,acceptsStartupDeadline:true)
        let named=try Self.refusal{try older.requirePrefixSSDKeyInput(tierOn:true)}
        try require(named.contains("cannot take the prefix-SSD key on its input"),"an older worker was not refused by name: \(named)")
        try older.requirePrefixSSDKeyInput(tierOn:false)
        try prepared.validation.workerFeatures.requirePrefixSSDKeyInput(tierOn:true)
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
            let arguments=try withoutBootstrap(rankPlan,binding:binding,deadline:deadline)
            // The same setup without the field: the pipeline's command line, to which the mode adds exactly one pair.
            member.removeValue(forKey:"generationMode")
            let pipeline=try DistributedInstalledPlan(saved:.init(configuration:ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject:member),
                capability:split.capability,capabilitySHA256:split.configuration.capabilitySHA256),capability:split.capability),paths:split.paths)
            let plain=try withoutBootstrap(pipeline,binding:binding,deadline:deadline)
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
    /// The waits come from the setup and the verified artifact, not a per-model
    /// row (owner, 2026-10-14): the request deadline the planner derived, the
    /// longest prompt the worker admits, the artifact's size and the largest
    /// stage. The fixture (a 10 s deadline, a few hundred bytes) gets exactly
    /// the figures the path has always used for the 9B.
    static func perModelBudgets(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation) throws {
        let nine=DistributedInstalledTimeBudgets(startupAllowanceNanoseconds:90_000_000_000,firstTokenBaseMilliseconds:10_000,firstTokenMillisecondsPerPromptToken:1,
            admissionWaitNanoseconds:5_000_000_000,shutdownAcknowledgementNanoseconds:2_000_000_000,stopMarginNanoseconds:15_000_000_000,
            cleanStopWaitNanoseconds:10_000_000_000)
        let derived=DistributedInstalledPlan.budgets(configuration:prepared.plan.configuration,capability:prepared.plan.capability,
            partition:prepared.plan.partition,artifactBytes:prepared.manifest.totalSizeBytes)
        try require(prepared.plan.budgets==derived.0 && prepared.plan.budgetBasis==derived.1,"the plan's budgets are not the ones its setup and artifact derive")
        try require(prepared.plan.budgets==nine,"the fixture's derived budgets moved from the 9B's figures: \(prepared.plan.budgets)")
        try require(prepared.plan.budgetBasis.count==3 && prepared.plan.budgetBasis[1].contains("request deadline"),"the budgets say how they were derived")
        try require(nine.pairTiming == ClusterWorkerPairTiming(admissionWaitNanoseconds:5_000_000_000,shutdownAcknowledgementNanoseconds:2_000_000_000,cleanStopWaitNanoseconds:10_000_000_000),"the 9B's pair timing differs")
        let (session,_)=try session(f,prepared)
        try require(try session.firstTokenBudgetPolicy() == DistributedFirstTokenBudgetPolicy(baseMilliseconds:10_000,millisecondsPerInputToken:1),"9B first-token budget changed")
        try require(session.cooperativeStopAllowanceNanoseconds==85_000_000_000,"9B stop allowance changed")
        // A phase split of the same tiny artifact stays at the startup floor.
        let split=try InstalledFixture.make(root:f.root.appendingPathComponent("budget-split"),probe:f.probe,owner:f.owner,worker:f.worker,
            generationMode:"phase_split_v1",advertisedModes:allModes).prepare()
        try require(split.plan.budgets==nine,"a phase split of a tiny artifact changed a time budget")
        // A longer planned deadline gives a larger first-token share; the setup, not the model, decides.
        let longer=try InstalledFixture.make(root:f.root.appendingPathComponent("budget-long"),probe:f.probe,owner:f.owner,worker:f.worker,
            lifetimeSeconds:330).prepare()
        try require(longer.plan.budgets.firstTokenMillisecondsPerPromptToken==40 && longer.plan.budgets.cleanStopWaitNanoseconds==60_000_000_000,
            "a 330 s planned deadline: \(longer.plan.budgets)")
        // Every derived timing is one the pair accepts: the pair refuses a wait above one minute before it looks at its
        // workers (round 6f hardware: a 27B setup's clean-stop wait of 2 x the predicted request ended both ranks at
        // startup with "Pair waits must be between one nanosecond and one minute").
        for seconds in [60,330,900,3_600] {
            let timing=DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds:seconds,maximumPromptTokens:8192,artifactBytes:15_100_000_000,
                largestStageShare:0.75,lastRankLoadsEverything:false).budgets.pairTiming
            do { _=try ClusterWorkerPair(workers:[],startupDeadline:0,timing:timing); try require(false,"an empty pair formed") }
            catch ClusterWorkerOwnerError.invalid(let message) {
                try require(message != "Pair waits must be between one nanosecond and one minute","a \(seconds) s deadline derives a timing the pair refuses: \(timing)")
            }
        }
        // Real artifact sizes: the startup allowance covers three times every ready time the pair recorded (pipeline and
        // phase split; seconds), and stays inside the protocol's hour.
        let sizes:[(String,Double,Double,Double)]=[("9B",5.0,7.3,12.3),("27B",15.1,13.7,23.0),("35B A3B",20.9,25.8,29.0),("36 A3B",21.3,25.1,30.6),
            ("Bonsai",8.6,9.4,11.8),("Nemotron",19.1,16.8,19.7),("MiMo",172.9,63.7,63.7),("GPT-OSS",13.8,0,0),("Gemma 4 QAT4",15.6,0,0)]
        for (name,gigabytes,pipelineReady,splitReady) in sizes {
            let bytes=Int64(gigabytes*1e9)
            let pipeline=DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds:300,maximumPromptTokens:8192,artifactBytes:bytes,
                largestStageShare:0.75,lastRankLoadsEverything:false).budgets
            let whole=DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds:300,maximumPromptTokens:8192,artifactBytes:bytes,
                largestStageShare:0.75,lastRankLoadsEverything:true).budgets
            try require(Double(pipeline.startupAllowanceNanoseconds)/1e9>=3*pipelineReady && Double(whole.startupAllowanceNanoseconds)/1e9>=3*splitReady
                && whole.startupAllowanceNanoseconds<ClusterWorkerLimits.deadlineNanoseconds,"\(name): startup allowance")
            try require(pipeline.shutdownAcknowledgementNanoseconds>=2_000_000_000 && pipeline.stopMarginNanoseconds>=15_000_000_000
                && pipeline.admissionWaitNanoseconds==5_000_000_000,"\(name): release and admission waits")
        }
    }
    /// No session lifetime (handoff/DESIGN-no-fixed-lifetime.md): a long
    /// prompt with 128 outputs is bounded only by the setup's request budgets.
    /// The pair's measured first token at the longest prompt each model has
    /// run across the cable (both Macs, normal order) is inside the allowance a
    /// setup gets when the planner predicted exactly what was measured.
    static func longPromptsFitTheInstalledSession(_ f:InstalledFixture) throws {
        // 9B and 27B at 30,720 prompt tokens, medians after one warm-up (evidence/longctx-20261009, hw-9b
        // and hw-27b TABLE.txt): the slower Mac decoding alone, tokens a second (9B 67.6, 27B 23.3, both
        // Mac B), rounded down; the pair's first token in the pipeline mode, seconds, rounded up. The
        // other families at 16,384 tokens, one run each (evidence/universal-20261010/hw/<family>/p16k-*).
        let measured:[String:(prompt:Int,decode:Double,pairFirstToken:Double)]=["registered_qwen35_9b":(30_720,67,15.61),
            "registered_qwen38_27b":(30_720,23,39.91),"registered_qwen35_35b_a3b":(16_384,65,8.68),
            "registered_qwen36_35b_a3b":(16_384,65,8.33),"registered_ternary_bonsai_2_27b":(16_384,29,45.52),
            "registered_nemotron35_lightning":(16_384,77,8.28),
            // MiMo at the planner's cut 14 (M5 Ultra rank 0 with 14 layers, M3 Ultra rank 1 with 34 and the head: the slower
            // of its two qualified placements), 2026-10-13 (evidence/mimo-qual-20261013/qual/mimo-c14/p16k-*; cut 47: 17.40 s).
            "registered_mimo_v26_flash_mopd":(16_384,28,37.66)]
        for (model,rates) in measured {
            // `ClusterPlacementRequestLimits.requestTimeoutSeconds` for a prediction exactly as fast as measured.
            let deadline=min(3600,max(60,Int((3*(rates.pairFirstToken+128/rates.decode)+30).rounded(.up))))
            let budgets=DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds:deadline,maximumPromptTokens:rates.prompt,
                artifactBytes:nil,largestStageShare:0.75,lastRankLoadsEverything:false).budgets
            let firstToken=Double(budgets.firstTokenBaseMilliseconds+Int64(rates.prompt)*budgets.firstTokenMillisecondsPerPromptToken)/1000
            try require(3*rates.pairFirstToken<=firstToken,"\(model): measured first token \(rates.pairFirstToken) s is not a third of its \(firstToken) s allowance")
        }
    }
    /// The owner's serving (2026-10-14 08:45): any model a cluster stage
    /// adapter runs is prepared on any Apple silicon, whatever its records; the
    /// records add only its public grant and the shapes that diverged. The 27B
    /// prepares in every mode, whatever the public name; a model no adapter
    /// runs is refused; an artifact no record ran is prepared with no public grant.
    static func pairServingGrant(_ f:InstalledFixture) throws {
        let model=("registered_qwen38_27b","registered_qwen38_27b_greedy_generation_v1","EigenLabs/Qwen3.8-27B-4bit-mtp")
        for (name,mode) in [("q27",nil),("q27-split","phase_split_v1")] as [(String,String?)] {
            let big=try InstalledFixture.make(root:f.root.appendingPathComponent(name),probe:f.probe,owner:f.owner,worker:f.worker,
                generationMode:mode,advertisedModes:allModes,registered:model)
            let prepared=try big.prepare()
            try require(prepared.plan.serving.publicGrant==(try? ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"p"))
                && prepared.plan.serving.publicGrant != nil,"the 27B was prepared under another model's public grant")
            // The fixture is the leader: rank 0 of two. Any Apple silicon runs it; a chip with no class does not.
            for chip in ["Apple M3 Ultra","Apple M5 Max","Apple M4 Max","Apple M5 Pro"] { try prepared.plan.requireLocalRankGranted(chipClass:ClusterChipClass(chipName:chip)) }
            let refused=try refusal{try prepared.plan.requireLocalRankGranted(chipClass:ClusterChipClass(chipName:"Apple M1 (Virtual)"))}
            try require(refused.contains("EigenLabs/Qwen3.8-27B-4bit-mtp") && refused.contains("registered_qwen38_27b") && refused.contains("rank 0")
                && refused.contains("not Apple silicon") && refused.contains("policy decision"),"a classless chip was not refused for the 27B's rank 0: \(refused)")
        }
        let nine=try f.prepare()
        try require(nine.plan.serving.publicGrant==(try? ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen35_9b",publicModelID:"p")),"the 9B was prepared under another model's public grant")
        for chipClass in [ClusterChipClass.appleM3Ultra, .appleM5Max, ClusterChipClass(chipName:"Apple M4 Max")!] { try nine.plan.requireLocalRankGranted(chipClass:chipClass) }
        // Keyed on the runtime's model, whatever the public name.
        let renamed=try ClusterPairServingGrants.ownerServing(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")
        try require(try renamed==ClusterPairServingGrants.ownerServing(runtimeModelID:"registered_qwen38_27b",publicModelID:"p"),"renamed 27B serving differs")
        let unknown=try refusal{_ = try ClusterPairServingGrants.ownerServing(runtimeModelID:"registered_future",publicModelID:"future/model")}
        try require(unknown.contains("no cluster stage adapter") && unknown.contains("registered_future"),"a model no adapter runs must be refused: \(unknown)")
        let ungranted=try refusal{_ = try ClusterPairServingGrants.grant(runtimeModelID:"registered_future",publicModelID:"EigenLabs/Qwen3.8-27B-4bit-mtp")}
        try require(ungranted.contains("not yet qualified for public traffic") && ungranted.contains("registered_future"),"a model without records has no public grant: \(ungranted)")
        // An artifact no record ran (here the fixture's own files) is prepared for its owner, with no public grant.
        let foreign=try InstalledFixture.make(root:f.root.appendingPathComponent("q27-foreign"),probe:f.probe,owner:f.owner,worker:f.worker,
            advertisedModes:allModes,registered:model,standsForRegisteredArtifact:false)
        let other=try foreign.prepare()
        try require(other.plan.serving.publicGrant==nil && other.plan.serving.publicTrafficLine==ClusterPairOwnerServing.notYetQualified,
            "a capability whose artifact no record ran: \(other.plan.serving.publicTrafficLine)")
        let publicRefusal=try refusal{_ = try ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"p",
            artifactSHA256:foreign.capability.artifactSHA256)}
        try require(publicRefusal.contains("artifact") && publicRefusal.contains(String(foreign.capability.artifactSHA256.prefix(12))),
            "the foreign artifact's public refusal: \(publicRefusal)")
    }
    /// The installed path starts workers for every cluster stage adapter, each
    /// with the rank environment its arithmetic policy requires beside the
    /// values every rank is given (the pair driver's own values), under budgets
    /// derived from the setup; GPT-OSS and Gemma 4 included.
    static func adaptersOnTheInstalledPath(_ f:InstalledFixture) throws {
        let gemma=["MLX_GATHER_QMM_EXPERT_SLICES":"trust","MLX_GEMMA4_FUSED_WEIGHTED_UNSORT":"1"]
        let cases:[(String,ClusterRuntimeAdapter,String,[String:String],String?)]=[
            ("a35",.qwen35RoutedExperts,"registered_qwen35_35b_a3b",["MLX_GATHER_QMM_EXPERT_SLICES":"trust"],"phase_split_v1"),
            ("a36",.qwen35RoutedExperts,"registered_qwen36_35b_a3b",["MLX_GATHER_QMM_EXPERT_SLICES":"trust"],"phase_split_v1"),
            ("bonsai",.qwen35PrismHadamard,"registered_ternary_bonsai_2_27b",
                ["DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC":"1","DARKBLOOM_BONSAI_F16_CONSTANT_CACHE":"1"],"phase_split_v1"),
            ("nemotron",.nemotronH,"registered_nemotron35_lightning",[:],"phase_split_v1"),
            ("gptoss",.gptossLayerStage,"registered_gpt_oss_20b",[:],nil),
            ("gemma-qat4",.gemma4LayerStage,"registered_gemma4_26b_qat_4bit",gemma,nil),
            ("gemma-8bit",.gemma4LayerStage,"registered_gemma4_26b_8bit",gemma,nil)]
        for (name,adapter,model,extra,mode) in cases {
            let fixture=try InstalledFixture.make(root:f.root.appendingPathComponent("adapter-"+name),probe:f.probe,owner:f.owner,worker:f.worker,
                generationMode:mode,advertisedModes:allModes,registered:(model,model+"_greedy_generation_v1","fixture/"+name),adapter:adapter)
            let prepared=try fixture.prepare()
            let environment=prepared.plan.nativeEnvironment(matrix:prepared.matrixURL)
            // Plus exactly MLX's command-buffer operation guard every rank gets (orphan port #5; the megabyte cap is MLX's
            // own per chip unless an operator pins one) and the prefix SSD tier's two (directory, the plan's stop margin;
            // the key goes on the rank's input, never its environment).
            try require(environment.count==13+extra.count+(environment["MLX_MAX_MB_PER_BUFFER"]==nil ? 0 : 1)
                && extra.allSatisfy{environment[$0.key]==$0.value}
                && environment["MLX_MAX_OPS_PER_BUFFER"]=="16"
                && environment["MLX_ENABLE_TF32"]=="1" && environment["DARKBLOOM_BF16_WEIGHTS"]=="1" && environment["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"]=="128"
                && environment["JACCL_RANK"]=="0" && environment["JACCL_PROGRESS_TIMEOUT_MS"]=="60000","\(name): rank environment \(environment.keys.sorted())")
            let derived=DistributedInstalledPlan.budgets(configuration:prepared.plan.configuration,capability:prepared.plan.capability,
                partition:prepared.plan.partition,artifactBytes:prepared.manifest.totalSizeBytes).0
            try require(prepared.plan.budgets==derived && prepared.plan.serving.runtimeModelID==model,"\(name) was prepared under another model's budgets or serving")
            // The fixture is the leader: rank 0 at cut 4, which any Apple silicon may run unless that Mac's class ran rank 0
            // at cut 4 in a check that diverged (GPT-OSS on the M3 Ultra): then the start refuses it, as the planner does.
            let records=ClusterPairServingGrants.records(runtimeModelID:model)
            for chipClass in [ClusterChipClass.appleM3Ultra, .appleM5Max, ClusterChipClass(chipName:"Apple M4 Max")!] {
                let mode=prepared.plan.configuration.selectedGenerationMode
                if records.admitsRank(0,of:2,chipClass:chipClass,cuts:[4],mode:mode) {
                    try prepared.plan.requireLocalRankGranted(chipClass:chipClass)
                } else {
                    let steered=try refusal{try prepared.plan.requireLocalRankGranted(chipClass:chipClass)}
                    try require(steered.contains("diverged from its single-Mac reference") && steered.contains("cut 4"),"\(name) on \(chipClass): \(steered)")
                }
            }
            if model=="registered_gpt_oss_20b" {
                try require(!records.admitsRank(0,of:2,chipClass:.appleM3Ultra,cuts:[4],mode:.pipeline),"GPT-OSS's diverged rank-shape is steered away from at start")
            }
        }
        // The dense adapter's environment is the ten values it always had.
        try require(try f.prepare().plan.adapterEnvironment.isEmpty,"the dense adapter gained an environment value")
        // An adapter value can never replace one of the fixed ten.
        try require(DistributedInstalledPlan.adapterArithmeticEnvironment.values.allSatisfy{$0.keys.allSatisfy{key in
            !["PATH","LANG","LC_ALL","DARKBLOOM_CBV2_ATTN_QUERY_BLOCK","DARKBLOOM_BF16_WEIGHTS","MLX_ENABLE_TF32","JACCL_RANK","JACCL_IBV_DEVICES",
              "JACCL_COORDINATOR","JACCL_PROGRESS_TIMEOUT_MS"].contains(key)}},"an adapter names a fixed environment value")
        // The adapters this path starts are every cluster stage adapter this build has.
        try require(Set(DistributedInstalledPlan.adapterArithmeticEnvironment.keys)==Set(ClusterRuntimeAdapter.allCases),
            "the installed path's adapters and the runtime's adapters differ")
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
            && message.contains("Unknown generation mode") && message.contains("not built from the same tree")
            && message.hasPrefix("Install the same Darkbloom release on both Macs") && !message.contains("cluster configure"),
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
    typealias RankOne=@Sendable (DistributedInstalledPlan,ClusterWorkerIdentity,UInt64,(any ClusterOwnerBootstrapExchange)?) throws->any ClusterOwnedWorkerEndpoint
    static func session(_ f:InstalledFixture,_ prepared:DistributedInstalledPreparation,behavior:String="normal",failSecond:Bool=false,
                        rankOne:RankOne?=nil) throws->(DistributedInstalledSession,EndpointBox) {
        let base=f.root.appendingPathComponent("session-"+UUID().uuidString);try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let box=EndpointBox()
        let session=try DistributedInstalledSession(prepared:prepared,endpointFactory:{ plan,id,rank,lifetime,relay,_ in
            if failSecond && rank==1 { throw CheckFailure(message:"fabricated second launch refusal") }
            if rank==1, let rankOne { return try rankOne(plan,id,lifetime,relay) }
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
        // The surviving rank's worker was started into the combined bootstrap
        // for a peer that was never launched. The fence cancels its owner's
        // bootstrap listener, which refuses the worker's connection, so the
        // worker ends at once instead of at the bootstrap's own bound (30 s),
        // with its cleanup and release proven.
        let began=DispatchTime.now().uptimeNanoseconds
        let result=await s.stop(until:began+10_000_000_000)
        try require(DispatchTime.now().uptimeNanoseconds-began<5_000_000_000,"partial startup held the surviving rank inside its bootstrap")
        try require(box.snapshot.count==1 && box.snapshot[0].nativeCleanupObserved,"partial startup lost first endpoint: \(box.snapshot.map { "termination \(String(describing:$0.ownerTermination)) cleanup \($0.nativeCleanupObserved) tail \(String(decoding:$0.diagnosticTail,as:UTF8.self).suffix(600))" })")
        try require(result == .released || result == .quarantined,"partial startup returned live readiness")
        try require(!s.canRotate || box.snapshot[0].ownerDeviceLeaseReleasedObserved,"partial rotate missing release")
    }
    /// A follower member that refuses the open (here its setup is for another
    /// plan) ends the start with its own reason instead of a bare closed
    /// stream, and the surviving rank is released as at any partial start.
    /// The follower is the real link server, joined to the leader's link
    /// endpoint in this process (no socket, no SSH).
    static func followerRefusalNamed(_ f:InstalledFixture,_ p:DistributedInstalledPreparation) async throws {
        final class Loop: ClusterLinkWorkerTransport, @unchecked Sendable {
            let lock=NSLock(); var target:(@Sendable (Data)->Void)?
            func send(_ bytes:Data) throws {
                guard let target=lock.withLock({ self.target }) else { throw CheckFailure(message:"link loop not joined") }
                target(bytes)
            }
        }
        let toFollower=Loop(),toLeader=Loop(),router=ClusterLinkWorkerRouter()
        let server=ClusterLinkWorkerServer(transport:toLeader,clusterID:p.plan.configuration.clusterID,rank:1,
            bootstrapProfile:p.plan.bootstrap.ownerProfile,admit:{ _ in throw ClusterConfigurationError.invalid("The leader opened another plan") })
        toLeader.lock.withLock { toLeader.target={ router.deliver($0) } }
        toFollower.lock.withLock { toFollower.target={ server.deliver($0) } }
        let(s,box)=try session(f,p,rankOne:{ plan,id,lifetime,relay in
            try ClusterLinkWorkerEndpoint(transport:toFollower,clusterID:plan.configuration.clusterID,expectedIdentity:id,
                profile:plan.capability.profile,rank:1,executionPlanSHA256:plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds:lifetime,bootstrapRelay:relay,router:router)
        })
        var named:String?
        do { try await s.start() }
        catch let refusal as DistributedInstalledStartRefusal {
            try require(refusal.rank==1,"the refusal names rank \(refusal.rank)")
            named=String(describing:refusal)
        }
        try require(named?.contains("refused the session") == true && named?.contains("The leader opened another plan") == true,
            "the start did not carry the follower's reason: \(String(describing:named))")
        let began=DispatchTime.now().uptimeNanoseconds
        let result=await s.stop(until:began+10_000_000_000)
        try require(DispatchTime.now().uptimeNanoseconds-began<5_000_000_000,"a refused follower held the surviving rank")
        try require(box.snapshot.count==1 && box.snapshot[0].nativeCleanupObserved,"the surviving rank was not cleaned up")
        try require(result == .released || result == .quarantined,"a refused start returned live readiness")
        try require(!server.busy && server.served==0,"the refusing follower launched something")
        // Any other failure is passed through unchanged; the reason prints as plain ASCII.
        try require(DistributedInstalledSession.startFailure(ClusterWorkerOwnerError.closed,endpoints:[]) as? ClusterWorkerOwnerError == .closed,
            "a failure without a refusal was rewritten")
        try require(DistributedInstalledStartRefusal(rank:1,reason:"a\u{1b}[2Jb\u{7f}").reason=="a?[2Jb?","a refusal reason kept control characters")
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
    /// A graceful stop whose wait is under way when a stop nobody asked for
    /// arrives: the rest of the wait is bounded by the unrequested-stop
    /// allowance from that moment (finishStop used to keep the graceful,
    /// unbounded wait it had started with).
    static func stopBoundAfterGracefulThenUnrequested() async throws {
        let ms:UInt64=1_000_000
        func now()->UInt64 { DispatchTime.now().uptimeNanoseconds }
        // The pair's shutdown never returns; the stop began gracefully.
        let bound=DistributedInstalledStopBound(allowanceNanoseconds:300*ms)
        let began=now()
        Task { try? await Task.sleep(nanoseconds:200*ms); bound.beginUnrequested() }
        let shutdown:Bool?=await bound.wait(until:nil) { try? await Task.sleep(nanoseconds:5_000*ms); return true }
        let took=(now()-began)/ms
        try require(shutdown==nil && took>=450 && took<2_000,"the shutdown wait after an unrequested stop took \(took) ms (allowance 300 ms from 200 ms)")
        // A release wait with an owner ceiling far away: cut to the allowance's end too.
        let release=DistributedInstalledStopBound(allowanceNanoseconds:300*ms)
        let start=now()
        Task { try? await Task.sleep(nanoseconds:100*ms); release.beginUnrequested() }
        let proof:Bool?=await release.wait(until:now()+60_000*ms) { try? await Task.sleep(nanoseconds:5_000*ms); return true }
        let waited=(now()-start)/ms
        try require(proof==nil && waited>=350 && waited<2_000,"the release wait after an unrequested stop took \(waited) ms")
        // Already unrequested before the wait: bounded from the start; a body that ends first is returned.
        let early=DistributedInstalledStopBound(allowanceNanoseconds:300*ms); early.beginUnrequested()
        let quick:Bool?=await early.wait(until:nil) { try? await Task.sleep(nanoseconds:20*ms); return true }
        try require(quick==true,"a body that ends inside the allowance is returned")
        // Asked-for only: no bound of its own; the caller's deadline still applies.
        let graceful=DistributedInstalledStopBound(allowanceNanoseconds:300*ms)
        let g0=now()
        let late:Bool?=await graceful.wait(until:now()+700*ms) { try? await Task.sleep(nanoseconds:5_000*ms); return true }
        let gw=(now()-g0)/ms
        try require(late==nil && gw>=650 && gw<2_000 && graceful.allowanceEnd==nil,"a graceful wait took \(gw) ms (deadline 700 ms)")
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

/// Synthetic chip classes for the checks: the classes these fixtures run as.
/// Product code names no chip; a class comes from the chip's own name.
extension ClusterChipClass {
    static let appleM3Ultra = ClusterChipClass(chipName: "Apple M3 Ultra")!
    static let appleM5Max = ClusterChipClass(chipName: "Apple M5 Max")!
}
