import Foundation
import CryptoKit
import Darwin
import DarkbloomClusterProtocol
import ProviderCoreFoundation
@testable import InstalledContract

struct InstalledFixture: Sendable {
    let root: URL, probe: URL, owner: URL, worker: URL
    let configuration: ClusterConfiguration, capability: ClusterRuntimeCapability
    let reference: ClusterConfigurationReference, paths: ClusterUserPaths
    let manifestBytes: Data
    func prepare() throws -> DistributedInstalledPreparation {
        try .prepare(reference: reference, paths: paths, deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
    }
    static func make(root: URL, probe: URL, owner: URL, worker: URL, lifetimeSeconds: Int = 10,
                     startupPreparation: ClusterRuntimeStartupPreparation? = nil) throws -> Self {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func hash(_ data: Data) -> String { ClusterConfigurationCodec.sha256(data) }
        func pin(_ character: Character) -> String { String(repeating: String(character), count: 64) }
        let config = try bytes(["model_type":"qwen3_5", "text_config":["eos_token_id":7,"vocab_size":248320]])
        let named: [(String, String, Data)] = [("config.json","config",config),("tokenizer.json","tokenizer",Data("{}".utf8)),
            ("tokenizer_config.json","tokenizer",Data("{}".utf8)),("chat_template.jinja","template",Data("synthetic template".utf8))]
        for (name, _, data) in named { try data.write(to: model.appendingPathComponent(name)) }
        // The fabricated weight inventory has no corresponding payload file.
        let inventory = named + [("model.safetensors","weight",Data("no payload read".utf8))]
        var aggregate = SHA256()
        for (_,_,data) in inventory.sorted(by: { $0.0 < $1.0 }) { aggregate.update(data: Data(SHA256.hash(data: data))) }
        let artifact = aggregate.finalize().map { String(format:"%02x",$0) }.joined()
        let manifest = try bytes(["schema_version":1,"model_id":"fixture/public-model","version":"fixture-v1","r2_prefix":"fixture/prefix",
            "aggregate_sha256":artifact,"total_size_bytes":inventory.reduce(0){$0+$1.2.count},"file_count":inventory.count,
            "created_at":"2026-09-15T00:00:00Z","files":inventory.map { ["path":$0.0,"role":$0.1,"sha256":hash($0.2),"size_bytes":$0.2.count] as [String:Any] }])
        try manifest.write(to: model.appendingPathComponent("manifest.json"))
        let binary = hash(try Data(contentsOf: probe))
        let profile = ClusterWorkerProfile(id:"registered_qwen35_9b_greedy_generation_v1",vocabularySize:248320,
            maximumPromptTokens:8192,maximumOutputTokens:128,maximumChunkTokens:512,maximumContextTokens:8320)
        let cap = try ClusterRuntimeCapability(runtimeBinarySHA256:binary,adapterID:"qwen35-dense-layer-stage",adapterVersion:1,
            runtimeModelID:"registered_qwen35_9b",artifactSHA256:artifact,configurationSHA256:hash(config),manifestSHA256:hash(manifest),
            profile:profile,profileFingerprint:pin("e"),partitions:[.init(planSHA256:pin("f"),stages:[
                .init(rank:0,sourceLayerStart:0,sourceLayerEnd:4,stagePlanSHA256:pin("1"),constructionConfigurationSHA256:pin("2")),
                .init(rank:1,sourceLayerStart:4,sourceLayerEnd:32,stagePlanSHA256:pin("3"),constructionConfigurationSHA256:pin("4"))])],
            arithmeticPolicyID:"qwen_cbv2_query128_bf16_tf32_default_v1",arithmeticPolicySHA256:pin("5"),maxLifetimeSeconds:lifetimeSeconds,maxRequests:16,
            startupPreparation:startupPreparation)
        let capBytes = try ClusterRuntimeCapabilityCodec.encode(cap), capHash = hash(capBytes)
        try capBytes.write(to: model.appendingPathComponent("fixture-capability.json"))
        let key=root.appendingPathComponent("key"),hosts=root.appendingPathComponent("known_hosts")
        try Data("synthetic-private-key-fixture".utf8).write(to:key); chmod(key.path,0o600)
        let known=Data("synthetic public host pin\n".utf8);try known.write(to:hosts)
        func peer(_ rank:Int)->[String:Any] {
            ["id":"peer-\(rank)","rank":rank,"host":"peer-\(rank).local","port":22,"user":"fixture",
             "ownerExecutable":owner.path,"workerExecutable":probe.path,"modelDirectory":model.path,
             "runtimeBinarySHA256":binary,"jacclDevice":"rdma_en\(rank)"]
        }
        let object:[String:Any]=["schema":ClusterConfiguration.schemaName,"clusterID":"installed-fixture","memberID":"peer-0","role":"leader",
            "publicModelID":"fixture/public-model","capabilitySHA256":capHash,"selectedPlanSHA256":pin("f"),"chunkTokens":2,"requestTimeoutSeconds":lifetimeSeconds,
            "peers":[peer(0),peer(1)],"coordinator":["address":"192.168.2.1","port":12345],
            "trust":["identityFile":key.path,"knownHostsFile":hosts.path,"knownHostsSHA256":hash(known)],
            "tokenizerFiles":named.filter{$0.1 != "config"}.map{["path":$0.0,"sha256":hash($0.2),"purpose":$0.1 == "template" ? "chatTemplate":"tokenizer"]}]
        let input=root.appendingPathComponent("input.json"),capInput=root.appendingPathComponent("capability.json")
        try bytes(object).write(to:input);try capBytes.write(to:capInput)
        let configuration=try ClusterConfigurationCodec.decode(bytes(object),capability:cap,capabilitySHA256:capHash)
        let paths=try ClusterUserPaths(homeDirectory:root)
        var reference:ClusterConfigurationReference?
        _ = try ClusterConfigurationStore(paths:paths).save(configurationInput:input,capabilityInput:capInput,capabilitySHA256:capHash) { reference=$0 }
        return .init(root:root,probe:probe,owner:owner,worker:worker,configuration:configuration,capability:cap,
            reference:reference!,paths:paths,manifestBytes:manifest)
    }
}
