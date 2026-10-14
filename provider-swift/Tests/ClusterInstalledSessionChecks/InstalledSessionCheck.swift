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
            case .token(let token): tokens.append((token,time))
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
        print("Installed owner/session: metadata, bootstrap selection, progress guard, provider exclusion, generation mode, per-model budgets, long prompts within the request budgets, per-model pair-serving grants by chip class, the developer-only SSH route, bounded IO and 9 lifecycle scenarios passed; no native model, SSH or network")
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
        try require(Set(Table.rows.map(\.runtimeModelID))==Set(ClusterPairServingGrants.granted.map(\.runtimeModelID)),"the table's rows and the granted models differ")
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
            "registered_nemotron35_lightning":(16_384,77,8.28),
            // MiMo at the planner's cut 14 (M5 Ultra rank 0 with 14 layers, M3 Ultra rank 1 with 34 and the head: the slower
            // of its two qualified placements), 2026-10-13 (evidence/mimo-qual-20261013/qual/mimo-c14/p16k-*; cut 47: 17.40 s).
            "registered_mimo_v26_flash_mopd":(16_384,28,37.66)]
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
            try require(prepared.plan.grant==ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"p"),"the 27B was prepared under another model's grant")
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
        try require(nine.plan.grant==ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen35_9b",publicModelID:"p"),"the 9B was prepared under another model's grant")
        try nine.plan.requireLocalRankGranted(chipClass:.appleM3Ultra)
        let led=try refusal{try nine.plan.requireLocalRankGranted(chipClass:.appleM5Max)}
        try require(led.contains("pipeline-only rank on apple_m3_ultra") && led.contains("apple_m5_max"),"9B led by the M5 Max: \(led)")
        // Budgets and grant are keyed on the runtime's model, whatever the public name.
        let renamed=try Table.servingBudgets(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")
        try require(renamed==Table.qwen38.budgets,"renamed 27B budgets differ")
        try require(try ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"renamed/public-id")==ClusterPairServingGrants.grant(runtimeModelID:"registered_qwen38_27b",publicModelID:"p"),
            "renamed 27B grant differs")
        let unknown=try refusal{_ = try Table.servingBudgets(runtimeModelID:"registered_future",publicModelID:"future/model")}
        try require(unknown.contains("no row for the registered model registered_future"),"a model without a row must be refused: \(unknown)")
        let ungranted=try refusal{_ = try ClusterPairServingGrants.grant(runtimeModelID:"registered_future",publicModelID:"EigenLabs/Qwen3.8-27B-4bit-mtp")}
        try require(ungranted.contains("has no grant") && ungranted.contains("registered_future"),"a model without a grant must be refused: \(ungranted)")
        // A grant rests on records of the installed artifact: the 27B's records ran its registered artifact, and an
        // installed capability with any other artifact (here the fixture's own files) is refused before anything starts.
        let foreign=try InstalledFixture.make(root:f.root.appendingPathComponent("q27-foreign"),probe:f.probe,owner:f.owner,worker:f.worker,
            advertisedModes:allModes,registered:model,standsForRegisteredArtifact:false)
        let other=try refusal{_ = try foreign.prepare()}
        try require(other.contains("registered_qwen38_27b") && other.contains("artifact") && other.contains(String(foreign.capability.artifactSHA256.prefix(12)))
            && other.contains("policy decision"),"a capability whose artifact no record ran was not refused: \(other)")
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
            // Plus exactly MLX's command-buffer operation guard every rank gets (orphan port #5; the megabyte cap is MLX's
            // own per chip unless an operator pins one) and the prefix SSD tier's two (directory, the plan's stop margin;
            // the key goes on the rank's input, never its environment).
            try require(environment.count==13+extra.count+(environment["MLX_MAX_MB_PER_BUFFER"]==nil ? 0 : 1)
                && extra.allSatisfy{environment[$0.key]==$0.value}
                && environment["MLX_MAX_OPS_PER_BUFFER"]=="16"
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
