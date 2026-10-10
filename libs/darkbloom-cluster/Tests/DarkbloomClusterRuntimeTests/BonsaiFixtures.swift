import Foundation
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRuntime

// Shared inputs of the Bonsai suites: the registered configuration and
// manifest (byte-exact copies of the artifact's own files, 60 KB together) and
// the canonical tensor inventory. The inventory is not a file. A Prism pack's
// layout is regular, so the 1,655 descriptors are written out from the
// registered geometry below; the suites hold that list to the SHA-256 the
// specification pins, which was taken from the artifact's own safetensors
// header. No weight is read anywhere in these suites.
enum BonsaiFixture {
    static let now: UInt64 = 1_000
    static let matrix = Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8)
    static let cuts = Array(stride(from: 4, through: 60, by: 4))
    static let modelID = "registered_ternary_bonsai_2_27b"
    static let profileID = "registered_ternary_bonsai_2_27b_greedy_generation_v1"

    static func data(_ model: String, _ name: String) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }
    static func data(_ name: String) throws -> Data { try data("ternary-bonsai-2-27b", name) }

    static func specification(_ model: QwenRegisteredDenseModel = .ternaryBonsai2TwentySevenB) throws -> QwenDenseRegisteredSpecification {
        guard let value = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
            throw ProbeError("no specification")
        }
        return value
    }

    /// The dense contract's three values and the pack's two switches.
    static func environment(rank: Int = 0) -> [String: String] {
        ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
         "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC": "1", "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE": "1",
         "JACCL_RANK": String(rank), "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json",
         "JACCL_COORDINATOR": "10.0.0.5:4499"]
    }

    static func identity(epoch: UUID = UUID(), model: String = modelID, configSHA: String? = nil,
                         artifactSHA: String? = nil) throws -> ClusterWorkerIdentity {
        let spec = try specification()
        return ClusterWorkerIdentity(membershipEpoch: epoch, modelID: model,
            artifactSHA256: artifactSHA ?? spec.artifactSHA256,
            configurationSHA256: configSHA ?? spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
    }

    static func configuration(rank: Int = 0, cut: Int = 24, schedule: ClusterPrefillSchedule = .serial,
                              deadline: UInt64 = now + 300_000_000_000,
                              identity: ClusterWorkerIdentity) -> QwenResidentLoadConfiguration {
        QwenResidentLoadConfiguration(identity: identity, modelDirectory: URL(fileURLWithPath: "/tmp"),
            rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, prefillSchedule: schedule)
    }

    /// One admission with every input valid unless the caller replaces it.
    static func admit(_ configuration: QwenResidentLoadConfiguration, config: Data? = nil, manifest: Data? = nil,
                      environment: [String: String]? = nil) throws -> QwenResidentAdmission {
        try QwenResidentAdmission(configuration: configuration,
            configBytes: try config ?? data("configuration"), manifestBytes: try manifest ?? data("manifest"),
            environment: environment ?? Self.environment(rank: configuration.rank),
            now: now, read: { _, _ in matrix })
    }

    static func admit(rank: Int = 0, cut: Int = 24) throws -> QwenResidentAdmission {
        try admit(configuration(rank: rank, cut: cut, identity: try identity()))
    }

    /// Every canonical text tensor of the pack, from its layout: a packed
    /// module is a U32 weight at 2 bits and F16 scales and biases at group
    /// 128; everything else is plain F32. The transform signs are not here.
    static func inventory() -> [QwenDenseCanonicalTensor] {
        var tensors: [QwenDenseCanonicalTensor] = []
        func packed(_ module: String, rows: Int, width: Int) {
            tensors.append(.init(name: module + ".weight", shape: [rows, width / 16], sourceDType: "U32",
                                 byteCount: rows * (width / 16) * 4))
            for suffix in ["scales", "biases"] {
                tensors.append(.init(name: module + "." + suffix, shape: [rows, width / 128], sourceDType: "F16",
                                     byteCount: rows * (width / 128) * 2))
            }
        }
        func plain(_ name: String, _ shape: [Int]) {
            tensors.append(.init(name: name, shape: shape, sourceDType: "F32", byteCount: shape.reduce(4, *)))
        }
        let root = "language_model."
        packed(root + "lm_head", rows: 248_320, width: 5120)
        packed(root + "model.embed_tokens", rows: 248_320, width: 5120)
        plain(root + "model.norm.weight", [5120])
        for layer in 0..<64 {
            let base = root + "model.layers.\(layer)."
            plain(base + "input_layernorm.weight", [5120]); plain(base + "post_attention_layernorm.weight", [5120])
            packed(base + "mlp.gate_proj", rows: 17408, width: 5120); packed(base + "mlp.up_proj", rows: 17408, width: 5120)
            packed(base + "mlp.down_proj", rows: 5120, width: 17408)
            if (layer + 1) % 4 == 0 {
                packed(base + "self_attn.q_proj", rows: 12288, width: 5120)
                packed(base + "self_attn.k_proj", rows: 1024, width: 5120)
                packed(base + "self_attn.v_proj", rows: 1024, width: 5120)
                packed(base + "self_attn.o_proj", rows: 5120, width: 6144)
                plain(base + "self_attn.q_norm.weight", [256]); plain(base + "self_attn.k_norm.weight", [256])
            } else {
                packed(base + "linear_attn.in_proj_qkv", rows: 10240, width: 5120)
                packed(base + "linear_attn.in_proj_z", rows: 6144, width: 5120)
                packed(base + "linear_attn.out_proj", rows: 5120, width: 6144)
                plain(base + "linear_attn.in_proj_a.weight", [48, 5120]); plain(base + "linear_attn.in_proj_b.weight", [48, 5120])
                plain(base + "linear_attn.conv1d.weight", [10240, 4, 1]); plain(base + "linear_attn.norm.weight", [128])
                plain(base + "linear_attn.A_log", [48]); plain(base + "linear_attn.dt_bias", [48])
            }
        }
        return tensors.sorted { $0.name < $1.name }
    }

    /// The names of the 402 sign tensors the artifact stores beside its packed modules.
    static func signNames() -> [String] {
        inventory().filter { $0.name.hasSuffix(".scales") }.map { String($0.name.dropLast("scales".count)) + "signs" }
    }

    static func profile() throws -> QwenRegisteredDenseModelProfile {
        try QwenRegisteredDenseModelProfile.admit(configuration: data("configuration"), manifest: data("manifest"),
            expectedArtifactAggregateSHA256: specification().artifactSHA256, canonicalTensors: inventory())
    }
}
