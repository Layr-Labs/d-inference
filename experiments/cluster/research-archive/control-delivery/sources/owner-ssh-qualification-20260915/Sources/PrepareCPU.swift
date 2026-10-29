import Foundation
import CryptoKit
import Darwin
import DarkbloomClusterProtocol

/// Writes one explicit model-free configuration set; performs no network IO.
@main struct PrepareCPU {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, args.allSatisfy({ $0.hasPrefix("/") }) else {
            throw QualificationFailure.invalid("Expected absolute NEW_CONFIG_DIR REMOTE_DIR KNOWN_HOSTS IDENTITY_FILE LOCAL_STANDIN")
        }
        let directory = URL(fileURLWithPath: args[0], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw QualificationFailure.invalid("Configuration destination already exists")
        }
        let (_, nativeSHA) = try readQualificationBytes(args[4], maximum: 4 * 1024 * 1024)
        func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let identity = ClusterWorkerIdentity(membershipEpoch: zero, modelID: "registered_qwen35_9b",
            artifactSHA256: hash(Data("CPU fixture: no model artifact".utf8)),
            configurationSHA256: hash(Data("CPU fixture: two selected tokens 9 and 10".utf8)),
            peers: [.init(id: "cpu-peer24", buildSHA256: nativeSHA), .init(id: "cpu-peer48", buildSHA256: nativeSHA)])
        let profile = ClusterWorkerProfile(id: "cpu-mesh2-two-token", vocabularySize: 128,
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
        let plan = hash(Data("CPU fixture: no layer execution plan".utf8))
        var templates: [String] = []
        for rank in 0..<2 {
            let ready = ClusterWorkerReady(identity: identity, rank: rank, profile: profile,
                executionPlanSHA256: plan, requestCapacityBytes: 4096)
            templates.append(try ClusterWorkerCodec.encode(.init(membershipEpoch: zero, sequence: 0, requestID: nil,
                event: .ready(ready))).base64EncodedString())
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        func write(_ name: String, _ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            bytes.append(10)
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        for rank in 0..<2 {
            try write("owner-rank\(rank).json", ["schema": "darkbloom_configured_worker_owner_v1", "clusterID": "cpu-ssh-qualification",
                "workerExecutable": args[1] + "/native-standin", "modelDirectory": args[1] + "/cpu-model-not-opened",
                "leaseDirectory": args[1] + "/lease", "stageCut": 4, "maximumLifetimeSeconds": 120,
                "workerEnvironment": [String: String](), "readyTemplateBase64": templates[rank]])
        }
        let hosts = ["192.0.2.250", "192.0.2.223"]
        let peers: [[String: Any]] = hosts.map { ["host": $0, "user": "gaj", "port": 22,
            "knownHostsFile": args[2], "identityFile": args[3], "installedOwner": args[1] + "/darkbloom-owner-qualification"] }
        try write("controller.json", ["schema": "darkbloom_owner_qualification_v1", "cpuQualification": true,
            "clusterID": "cpu-ssh-qualification", "readyTemplateBase64": templates[0], "peers": peers,
            "membershipEpoch": UUID().uuidString.lowercased(), "requestID": UUID().uuidString.lowercased(),
            "promptTokenIDs": [1, 2, 3], "stopTokenIDs": [Int](), "outputCount": 2, "chunkSize": 2,
            "expectedTokenIDs": [9, 10], "lifetimeSeconds": 120, "startupSeconds": 30, "requestSeconds": 15])
        try write("scope.json", ["schema": "owner_cpu_configuration_scope_v1", "cpuQualification": true,
            "nativeStandInSHA256": nativeSHA, "nativeNumerics": false, "performanceQualification": false,
            "modelArtifactAndPlan": "Explicit fabricated fixture hashes; no model directory is opened",
            "requestCapacityBytesPerRank": "4096 fabricated bookkeeping bytes; no hardware capacity claim",
            "hostKeyAndIdentityFiles": "Explicit pre-existing paths only; generator does not open authentication files"])
    }
}
