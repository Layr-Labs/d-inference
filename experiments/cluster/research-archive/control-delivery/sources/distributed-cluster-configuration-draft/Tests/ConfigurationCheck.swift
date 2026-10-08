import Foundation
import Darwin
import DarkbloomClusterProtocol

@main enum ConfigurationCheck {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    static func rejected(_ action: () throws -> Void) throws {
        do { try action() } catch is Failure { throw Failure(message: "Fixture assertion failed inside refusal") }
        catch { return }
        throw Failure(message: "Malformed setup was accepted")
    }
    static func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
    static func bytes(_ object: [String: Any], pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys])
    }
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("configuration-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClusterWorkerProfile(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248320,
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: "registered_qwen35_9b", artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: profile, profileFingerprint: hash("e"), partitions: [ClusterRuntimePartition(planSHA256: hash("f"), stages: [
                ClusterRuntimeStage(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 4, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                ClusterRuntimeStage(rank: 1, sourceLayerStart: 4, sourceLayerEnd: 32, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"), maxLifetimeSeconds: 300, maxRequests: 16)
        let capabilityData = try ClusterRuntimeCapabilityCodec.encode(capability)
        let capabilityHash = ClusterConfigurationCodec.sha256(capabilityData)
        let key = root.appendingPathComponent("key"), hosts = root.appendingPathComponent("known_hosts")
        try Data("synthetic-key-metadata-only".utf8).write(to: key)
        try require(chmod(key.path, 0o600) == 0, "Cannot make private fixture key")
        let hostsData = Data("peer-one ssh-ed25519 synthetic-public-fixture\n".utf8)
        try hostsData.write(to: hosts)
        func peer(_ rank: Int) -> [String: Any] {
            ["id": "peer-\(rank)", "rank": rank, "host": "peer-\(rank).local", "port": 22, "user": "fixture",
             "ownerExecutable": "/Users/developer/bin/darkbloom", "workerExecutable": "/Users/developer/bin/darkbloom-worker",
             "modelDirectory": "/Users/developer/model", "runtimeBinarySHA256": hash("a"), "jacclDevice": "rdma_en\(rank)"]
        }
        let object: [String: Any] = ["schema": ClusterConfiguration.schemaName, "clusterID": "fixture", "memberID": "peer-0", "role": "leader",
            "publicModelID": "fixture/qwen", "capabilitySHA256": capabilityHash, "selectedPlanSHA256": hash("f"),
            "chunkTokens": 512, "requestTimeoutSeconds": 300, "peers": [peer(0), peer(1)],
            "coordinator": ["address": "192.168.2.1", "port": 12345],
            "trust": ["identityFile": key.path, "knownHostsFile": hosts.path, "knownHostsSHA256": ClusterConfigurationCodec.sha256(hostsData)],
            "tokenizerFiles": [["path": "tokenizer.json", "sha256": hash("6"), "purpose": "tokenizer"],
                               ["path": "chat_template.jinja", "sha256": hash("7"), "purpose": "chatTemplate"]]]
        func decode(_ object: [String: Any]) throws -> ClusterConfiguration {
            try ClusterConfigurationCodec.decode(bytes(object), capability: capability, capabilitySHA256: capabilityHash)
        }
        let configuration = try decode(object)
        let canonical = try ClusterConfigurationCodec.encode(configuration, capability: capability, capabilitySHA256: capabilityHash)
        try require(try ClusterConfigurationCodec.decode(bytes(object, pretty: true), capability: capability, capabilitySHA256: capabilityHash) == configuration,
                    "Pretty input changed typed configuration")
        try require(try ClusterConfigurationCodec.encode(ClusterConfigurationCodec.decode(canonical, capability: capability, capabilitySHA256: capabilityHash),
            capability: capability, capabilitySHA256: capabilityHash) == canonical, "Canonical round trip differs")
        var follower = object; follower["role"] = "follower"; follower["memberID"] = "peer-1"
        try require(try decode(follower).localRank == 1, "Follower rank differs")

        // Closed schema, strict numeric syntax and all identity/policy joins.
        let changes: [(String, Any)] = [("schema", "other"), ("enabled", true), ("capacity", 100), ("environment", ["KEY": "VALUE"]),
            ("deviceLeaseDirectory", "/tmp/other"), ("role", "both"), ("memberID", "peer-1"), ("clusterID", "-option"),
            ("publicModelID", "bad\nmodel"), ("capabilitySHA256", hash("0")), ("selectedPlanSHA256", hash("0")),
            ("chunkTokens", 0), ("chunkTokens", 513), ("chunkTokens", true), ("requestTimeoutSeconds", 301), ("requestTimeoutSeconds", 0)]
        for (field, value) in changes { var bad = object; bad[field] = value; try rejected { _ = try decode(bad) } }
        for field in object.keys { var bad = object; bad.removeValue(forKey: field); try rejected { _ = try decode(bad) } }
        let text = String(decoding: canonical, as: UTF8.self)
        for altered in [text.replacingOccurrences(of: "\"chunkTokens\":512", with: "\"chunkTokens\":512.0"),
                        text.replacingOccurrences(of: "\"chunkTokens\":512", with: "\"chunkTokens\":512e0"),
                        text.replacingOccurrences(of: "\"chunkTokens\":512", with: "\"chunkTokens\":512,\"chunk\\u0054okens\":512")] {
            try require(altered != text, "Mutation did not affect source")
            try rejected { _ = try ClusterConfigurationCodec.decode(Data(altered.utf8), capability: capability, capabilitySHA256: capabilityHash) }
        }
        try rejected { _ = try ClusterConfigurationCodec.decode(Data(repeating: 32, count: 16385), capability: capability, capabilitySHA256: capabilityHash) }

        for (field, value) in [("rank", true as Any), ("rank", 0), ("host", "-Fconfig"), ("port", 65536), ("user", "u;command"),
                               ("runtimeBinarySHA256", hash("0")), ("modelDirectory", "/model/../other"),
                               ("workerExecutable", "/bin/worker $(cmd)"), ("jacclDevice", "a\nb")] {
            var badPeer = peer(1); badPeer[field] = value
            var bad = object; bad["peers"] = [peer(0), badPeer]
            try rejected { _ = try decode(bad) }
        }
        for peers in [[peer(0)], [peer(1), peer(0)], [peer(0), peer(0)], [peer(0), peer(1), peer(1)]] {
            var bad = object; bad["peers"] = peers; try rejected { _ = try decode(bad) }
        }
        for address in ["0.0.0.0", "127.0.0.1", "224.0.0.1", "192.168.02.1", "256.0.0.1", "localhost", "1.2.3.4:22"] {
            var bad = object; bad["coordinator"] = ["address": address, "port": 22]; try rejected { _ = try decode(bad) }
        }
        for files in [[], [["path": "../tokenizer", "sha256": hash("6"), "purpose": "tokenizer"]],
                      [["path": "tokenizer.json", "sha256": hash("6"), "purpose": "unknown"]],
                      [["path": "template", "sha256": hash("6"), "purpose": "chatTemplate"]],
                      Array(repeating: ["path": "same", "sha256": hash("6"), "purpose": "tokenizer"], count: 2)] {
            var bad = object; bad["tokenizerFiles"] = files; try rejected { _ = try decode(bad) }
        }
        let reference = try ClusterConfigurationReference(configuration: "/Users/developer/config", sha256: hash("a"))
        let referenceData = try JSONEncoder().encode(reference)
        var referenceObject = try JSONSerialization.jsonObject(with: referenceData) as! [String: Any]
        referenceObject["enabled"] = true
        try rejected { _ = try JSONDecoder().decode(ClusterConfigurationReference.self, from: bytes(referenceObject)) }

        let input = root.appendingPathComponent("input.json"), capabilityInput = root.appendingPathComponent("capability.json")
        try bytes(object, pretty: true).write(to: input); try capabilityData.write(to: capabilityInput)
        let paths = try ClusterUserPaths(homeDirectory: root), store = ClusterConfigurationStore(paths: paths)
        let pointer = root.appendingPathComponent("provider-pointer-fixture.json")
        var commits = 0
        func save(refuse: Bool = false) throws -> ClusterConfigurationSaveResult {
            try store.save(configurationInput: input, capabilityInput: capabilityInput, capabilitySHA256: capabilityHash) { reference in
                commits += 1
                let gate = try ClusterConfigurationFiles.directory(paths.deviceDirectory, privateMode: true)
                defer { Darwin.close(gate.descriptor) }
                try rejected { try ClusterConfigurationFiles.withLock(gate, name: "native-device.lease", requireEmpty: true, privateMode: true) {} }
                if refuse { throw ClusterConfigurationError.invalid("synthetic pointer refusal") }
                try ClusterConfigurationFiles.update(pointer, maximum: 8192) { _ in try JSONEncoder().encode(reference) }
            }
        }
        let result = try save(), repeated = try save()
        try require(result == repeated && commits == 2, "Repeated save did not retain immutable identities")
        let savedReference = try JSONDecoder().decode(ClusterConfigurationReference.self, from: Data(contentsOf: pointer))
        let saved = try store.load(reference: savedReference)
        try require(saved.configuration == configuration && saved.capability == capability, "Saved immutable records differ")
        let output = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        for field in ["distributedEnabled", "readinessVerified", "installationVerified", "modelFilesVerified", "remoteTrustVerified"] {
            try require(output[field] as? Bool == false, "Save result made an unverified claim")
        }
        let oldPointer = try Data(contentsOf: pointer)
        try rejected { _ = try save(refuse: true) }
        try require(try Data(contentsOf: pointer) == oldPointer, "Failed pointer update changed old reference")

        // A real held lock, or a sticky unresolved journal, blocks before the
        // provider pointer callback. Nothing truncates or recovers the journal.
        let device = try ClusterConfigurationFiles.directory(paths.deviceDirectory, privateMode: true)
        defer { Darwin.close(device.descriptor) }
        let before = commits
        try ClusterConfigurationFiles.withLock(device, name: "native-device.lease", requireEmpty: true, privateMode: true) {
            try rejected { _ = try save() }
        }
        let journal = Data("unresolved-native-owner\n".utf8)
        try journal.write(to: paths.deviceLeaseFile)
        try rejected { _ = try save() }
        try require(commits == before && (try Data(contentsOf: paths.deviceLeaseFile)) == journal,
                    "Device refusal invoked pointer update or erased journal")
        try Data().write(to: paths.deviceLeaseFile) // fixture-only explicit cleanup

        try Data("changed public trust input".utf8).write(to: hosts)
        try rejected { _ = try save() }
        try hostsData.write(to: hosts)
        try require(chmod(key.path, 0o644) == 0, "Cannot change fixture key mode")
        try rejected { _ = try save() }
        try require(chmod(key.path, 0o600) == 0, "Cannot restore fixture key mode")
        try Data("tampered capability".utf8).write(to: capabilityInput)
        try rejected { _ = try save() }
        try capabilityData.write(to: capabilityInput)
        try Data("tampered saved record".utf8).write(to: URL(fileURLWithPath: result.configuration))
        try rejected { _ = try store.load(reference: savedReference) }
        try require(try Data(contentsOf: pointer) == oldPointer, "Refused save replaced pointer")
        print("Cluster configuration: 10 schema/store groups passed; fabricated metadata and local files only")
    }
}
