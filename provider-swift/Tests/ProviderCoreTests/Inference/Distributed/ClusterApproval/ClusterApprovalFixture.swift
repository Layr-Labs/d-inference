import Foundation
import Testing
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// Two Macs of one pair on this machine, each with its own home: a real pairing ceremony between their pairing stores
/// (`ClusterPairingProviderTests.pair`), each Mac's installed owner and cluster helpers as files, and each Mac's saved
/// setup in its own configuration store, pointed to by its own provider configuration (whose coordinator is the test's
/// local HTTP server). The cluster runtime facts of an installation are given as values: describing a runtime needs
/// the native worker (`ClusterRuntimeApprovalFacts.describe`), which part of the release lane checks.
final class ClusterApprovalMacs: @unchecked Sendable {
    struct Mac {
        let rank: Int
        let home: URL
        let paths: ClusterUserPaths
        let pairing: ClusterPairingStore
        let provider: URL
        let scratch: URL
        let memberID: String
        let pin: String
        let owner: URL
        let worker: URL
        let model: URL
    }

    static func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }
    static let model = "fixture/qwen"
    static let chip = ClusterChipClass(chipName: "Apple M3 Ultra")

    let root: URL
    let capability: ClusterRuntimeCapability
    let capabilitySHA256: String
    let macs: [Mac]
    var leader: Mac { macs[0] }
    var follower: Mac { macs[1] }

    /// `coordinatorURL`: the coordinator both provider configurations name.
    init(coordinatorURL: String) throws {
        let h = Self.hash
        root = try NativePairMemberFixture.privateRoot()
        let profile = ClusterWorkerProfile(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248320,
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
        capability = try ClusterRuntimeCapability(runtimeBinarySHA256: h("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: "registered_qwen35_9b", artifactSHA256: h("b"), configurationSHA256: h("c"), manifestSHA256: h("d"),
            profile: profile, profileFingerprint: h("e"), partitions: [.init(planSHA256: h("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 16, stagePlanSHA256: h("1"), constructionConfigurationSHA256: h("2")),
                .init(rank: 1, sourceLayerStart: 16, sourceLayerEnd: 32, stagePlanSHA256: h("3"), constructionConfigurationSHA256: h("4"))])],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: h("5"))
        let capabilityData = try ClusterRuntimeCapabilityCodec.encode(capability)
        capabilitySHA256 = ClusterConfigurationCodec.sha256(capabilityData)

        let homes = try (0..<2).map { rank -> URL in
            let home = root.appendingPathComponent("mac-\(rank)", isDirectory: true)
            for folder in ["", ".darkbloom", "app", "app/Contents", "app/Contents/Helpers", "app/Contents/MacOS", "model", "scratch"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true),
                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            return home
        }
        let stores = homes.map { ClusterPairingStore.default(home: $0) }
        let signers = [ClusterPairingProviderTests.SoftwareSigner(), ClusterPairingProviderTests.SoftwareSigner()]
        let (leaderRecord, followerRecord) = try ClusterPairingProviderTests.pair(signers[0], signers[1], stores: (stores[0], stores[1]))
        let records = [leaderRecord, followerRecord]
        let pins = signers.map { ClusterMemberPin.of(uncompressedKey: $0.x963) }

        func file(_ url: URL, _ text: String, executable: Bool) throws {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
        var built: [Mac] = []
        for rank in 0..<2 {
            let home = homes[rank], helpers = home.appendingPathComponent("app/Contents/Helpers", isDirectory: true)
            let owner = home.appendingPathComponent("app/Contents/MacOS/darkbloom")
            let worker = helpers.appendingPathComponent("darkbloom-cluster-worker")
            try file(owner, "owner of mac \(rank)", executable: true)
            try file(worker, "worker", executable: true)
            try file(helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.placementToolName), "plan", executable: true)
            try file(helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.metallibName), "metallib", executable: false)
            try file(helpers.appendingPathComponent(ClusterRuntimeApprovalFacts.Installation.resourceLibraryName), "resource", executable: false)
            let provider = home.appendingPathComponent("provider.toml")
            try file(provider, "[coordinator]\nurl = \"\(coordinatorURL)\"\n", executable: false)
            built.append(Mac(rank: rank, home: home, paths: try ClusterUserPaths(homeDirectory: home), pairing: stores[rank],
                provider: provider, scratch: home.appendingPathComponent("scratch", isDirectory: true),
                memberID: ClusterSetupMemberFacts.memberID(pin: pins[rank]), pin: pins[rank], owner: owner, worker: worker,
                model: home.appendingPathComponent("model", isDirectory: true)))
        }
        macs = built
        for mac in macs {
            let secret = mac.home.appendingPathComponent("link.secret")
            try Data(repeating: 7, count: 32).write(to: secret, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            let record = records[mac.rank]
            func peer(_ other: Mac) -> [String: Any] {
                ["id": other.memberID, "rank": other.rank, "host": "192.0.2.\(other.rank + 1)", "port": 22, "user": "fixture",
                 "ownerExecutable": other.owner.path, "workerExecutable": other.worker.path, "modelDirectory": other.model.path,
                 "runtimeBinarySHA256": h("a"), "jacclDevice": "rdma_en7"]
            }
            let configuration: [String: Any] = ["schema": ClusterConfiguration.schemaName, "clusterID": record.clusterID,
                "memberID": mac.memberID, "role": mac.rank == 0 ? "leader" : "follower", "publicModelID": Self.model,
                "capabilitySHA256": capabilitySHA256, "selectedPlanSHA256": h("f"), "prefillSchedule": "serial_v1",
                "chunkTokens": 16, "requestTimeoutSeconds": 300, "peers": macs.map(peer),
                "coordinator": ["address": "192.0.2.1", "port": 12345],
                "linkControl": ["schema": ClusterLinkControlAttachment.schemaName, "port": 47999,
                                "linkEpoch": record.link.linkEpoch, "edgeID": record.link.edgeID, "secretFile": secret.path],
                "tokenizerFiles": [["path": "tokenizer.json", "sha256": h("6"), "purpose": "tokenizer"]]]
            let input = mac.scratch.appendingPathComponent("setup.json"), capabilityInput = mac.scratch.appendingPathComponent("capability.json")
            try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]).write(to: input)
            try capabilityData.write(to: capabilityInput)
            _ = try ClusterConfigurationStore(paths: mac.paths).configure(configurationInput: input, capabilityInput: capabilityInput,
                capabilitySHA256: capabilitySHA256, providerConfiguration: mac.provider)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A Mac's saved setup as its provider configuration points to it.
    func saved(_ mac: Mac) throws -> ClusterConfigurationStore.Saved {
        try #require(try ClusterApprovalAttachment.savedSetup(paths: mac.paths, providerConfiguration: mac.provider))
    }

    /// The exact bytes a Mac's provider configuration and saved setup hold now.
    func bytes(_ mac: Mac) throws -> [Data] {
        let reference = try #require(try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: mac.provider))
        return [try Data(contentsOf: mac.provider), try Data(contentsOf: URL(fileURLWithPath: reference.configuration))]
    }

    /// The cluster runtime facts both installations have; `differing` names one block field whose digest differs.
    func facts(differing: String? = nil) throws -> ClusterRuntimeApprovalFacts {
        let h = Self.hash
        // h("9") is no digest of either installation.
        func value(_ field: String, _ digest: String) -> String { field == differing ? h("9") : digest }
        return try ClusterRuntimeApprovalFacts(nativeRuntimeSHA256: value("native_runtime_sha256", h("a")),
            metallibSHA256: value("metallib_sha256", h("3")), resourceLibrarySHA256: value("resource_library_sha256", h("4")),
            placementPolicySHA256: value("placement_policy_sha256", h("7")),
            models: [.init(model: Self.model, artifactSHA256: value("artifact_sha256", h("b")),
                capabilitySHA256: value("capability_sha256", capabilitySHA256), profileSHA256: value("profile_sha256", h("e")),
                resourcePolicySHA256: value("resource_policy_sha256", h("8")))])
    }

    static let blockFields = ["native_runtime_sha256", "metallib_sha256", "resource_library_sha256", "placement_policy_sha256",
                              "artifact_sha256", "capability_sha256", "profile_sha256", "resource_policy_sha256"]

    /// The approval the coordinator derives from those facts (contract B), ending `seconds` from now.
    func approval(endsIn seconds: Double = 14 * 86_400, schedule: UInt8 = 1, model: String = ClusterApprovalMacs.model,
                  id: String? = nil) -> ClusterRuntimeApproval {
        let h = Self.hash
        let end = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down)))
        return ClusterRuntimeApproval(id: id ?? "release/0.10.4/\(model)/s\(schedule)", model: model, generation: 1,
            placementPolicySHA256: h("7"), artifactSHA256: h("b"), nativeRuntimeSHA256: h("a"), metallibSHA256: h("3"),
            resourceLibrarySHA256: h("4"), capabilitySHA256: capabilitySHA256, resourcePolicySHA256: h("8"), profileSHA256: h("e"),
            schedule: schedule, maximumTransportFrame: 1_048_616, maximumPlaintext: 1_048_576, maximumRecords: 1_048_576,
            maximumCumulativePlaintext: 4_294_967_296, allowedNumericsClasses: [], minimumMembers: 2, maximumMembers: 4,
            minimumMemberUsableBytes: 1, notAfter: end)
    }

    /// The endpoint's 200 body for `approvals`, field for field as the catalog file names them.
    static func body(_ approvals: [ClusterRuntimeApproval]) throws -> Data {
        let entries = try approvals.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["schema": ClusterApprovalFetch.schemaName, "cluster_approvals": entries],
                                          options: [.sortedKeys])
    }

    /// The cable to the follower: its cluster service's own `approval` handling against its own home, wrapped as the
    /// link exchange wraps a refusal. `facts` are the follower installation's facts.
    func cable(facts: ClusterRuntimeApprovalFacts, sent: ClusterApprovalSent? = nil) -> (ClusterServiceCommand) throws -> Void {
        let mac = follower
        return { command in
            sent?.append(command)
            do {
                _ = try ClusterApprovalSync.receive(command, paths: mac.paths, providerConfiguration: mac.provider,
                    pairingStore: mac.pairing, scratch: mac.scratch, now: Date().timeIntervalSince1970, say: { _ in },
                    chipClass: Self.chip, facts: { _ in facts })
            } catch {
                throw ClusterSetupFailure("the other Mac refused: " + ClusterApprovalSync.refusal(error))
            }
        }
    }

    /// The leader's step against the test coordinator's answer.
    func sync(_ fetched: ClusterApprovalFetch.Outcome, leaderFacts: ClusterRuntimeApprovalFacts,
              followerFacts: ClusterRuntimeApprovalFacts, sent: ClusterApprovalSent? = nil,
              now: Double = Date().timeIntervalSince1970) -> ClusterApprovalSync.Result {
        ClusterApprovalSync.run(fetched: fetched, paths: leader.paths, providerConfiguration: leader.provider,
            pairingStore: leader.pairing, scratch: leader.scratch, now: now,
            sendToPeer: cable(facts: followerFacts, sent: sent), chipClass: Self.chip, facts: { _ in leaderFacts })
    }

    /// The probe a serving leader records for the pair after a load.
    func recordLinkProbe() {
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 20,
            pointToPointLargeBytes: 4_194_304, pointToPointLargeMicroseconds: 400, allSumSmallBytes: 20_480,
            allSumSmallMicroseconds: 38, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 1_296)
        #expect(ClusterLinkProbeHistory.record(probe, members: macs.map(\.memberID), homeDirectory: leader.home))
    }
}

/// The commands the leader sent over the cable, in order.
final class ClusterApprovalSent: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClusterServiceCommand] = []
    func append(_ command: ClusterServiceCommand) { lock.withLock { values.append(command) } }
    var commands: [ClusterServiceCommand] { lock.withLock { values } }
}
