import CryptoKit
import Darwin
import Foundation

/// This public transcript proves no Darkbloom membership or device attestation.
/// The external lab owner authenticates these endpoints with pinned SSH keys.
struct LabRecordJob: Codable {
    let schema: String, identityKind: String, runID: String
    let rank: Int, payloadBytes: Int, warmups: Int, measurements: Int, timeoutSeconds: Int
    let hostKeySHA256: [String], nativeBuildSHA256: [String]
    let sourceSnapshotSHA256: String, mlxArtifactSHA256: String, secretCommitmentSHA256: String
    let expectedHardware: [String], expectedOSBuild: [String]
    static let payloads = [1, 5632, 8192, 10240, 65536, 131072, 360448, 720896, 1048576, 4194304, 5242880]
    static let modes = ["raw_payload", "raw_record_size", "encrypted_record", "encrypted_array"]
    var plaintextCeiling: Int { max(32, payloadBytes) }
    var frameCeiling: Int { plaintextCeiling + 40 }
    var rounds: Int { warmups + measurements }
    func validate() throws {
        guard schema == "lab_authenticated_rdma_component_v1", identityKind == "ssh_host_key_lab_only",
              UUID(uuidString: runID)?.uuidString.lowercased() == runID, (0...1).contains(rank),
              Self.payloads.contains(payloadBytes), warmups == 3, measurements == 20, timeoutSeconds == 120,
              hostKeySHA256.count == 2, Set(hostKeySHA256).count == 2, nativeBuildSHA256.count == 2,
              (hostKeySHA256 + nativeBuildSHA256 + [sourceSnapshotSHA256, mlxArtifactSHA256, secretCommitmentSHA256])
                .allSatisfy({ qwenStageWireIsSHA256($0) && $0 != String(repeating: "0", count: 64) }),
              expectedHardware.count == 2, expectedOSBuild.count == 2,
              (expectedHardware + expectedOSBuild).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\n") }) else {
            throw ProbeError("Lab record job identity or closed workload differs")
        }
    }
    var scopeSHA256: String {
        sha256(Data(([schema, identityKind, runID, String(payloadBytes), String(warmups), String(measurements),
            String(timeoutSeconds), sourceSnapshotSHA256, mlxArtifactSHA256, secretCommitmentSHA256]
            + hostKeySHA256 + nativeBuildSHA256 + expectedHardware + expectedOSBuild).joined(separator: "\n").utf8))
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 16_384 else { throw ProbeError("Lab record job exceeds16KiB") }
        try validateWorkerJSON(bytes)
        let value = try JSONDecoder().decode(Self.self, from: bytes); try value.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes), value)
        return value
    }
    func binding(_ domain: String) throws -> ClusterLabBinding {
        .init(epoch: UUID(uuidString: runID)!, plan: Data(SHA256.hash(data: Data((scopeSHA256 + "|" + domain).utf8))),
              transcript: Data(SHA256.hash(data: Data(("lab-only/ssh-authenticated-record/v1|" + scopeSHA256 + "|" + domain).utf8))))
    }
    func secretFromStdin() throws -> SymmetricKey {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0,
              ((info.st_mode & S_IFMT) == S_IFIFO ||
               ((info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0 && info.st_nlink <= 1)) else {
            throw ProbeError("Lab secret requires a private pipe or owned0600 stdin")
        }
        var bytes = Data()
        defer { bytes.resetBytes(in: 0..<bytes.count); close(STDIN_FILENO) }
        while bytes.count < 33 {
            guard let part = try FileHandle.standardInput.read(upToCount: 33 - bytes.count), !part.isEmpty else { break }
            bytes.append(part)
        }
        guard bytes.count == 32,
              sha256(Data("lab-record-secret-commitment/v1\0".utf8) + bytes) == secretCommitmentSHA256 else {
            throw ProbeError("Lab secret length or public commitment differs")
        }
        return SymmetricKey(data: bytes)
    }
}

struct ClusterLabBinding { let epoch: UUID; let plan: Data; let transcript: Data }
