import CryptoKit
import Foundation
@testable import ProviderCore

func runnerSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The managed load's checkpoint inputs (`NemotronSuperCheckpoint.Inputs`),
/// with the runner's identity record. `--preflight` stops here, so it reads
/// only small JSON/template files.
struct RunnerCheckpointInputs {
    let checkpoint: NemotronSuperCheckpoint.Inputs

    init(directory: URL, templateURL: URL?) throws {
        do { checkpoint = try NemotronSuperCheckpoint.Inputs(directory: directory, templateURL: templateURL) }
        catch let failure as NemotronSuperCheckpoint.Failure { throw RunnerFailure.checkpoint(failure.description) }
    }

    var json: RunnerJSON {
        [
            "config_sha256": .string(runnerSHA256(checkpoint.configData)),
            "config_bytes": .bytes(checkpoint.configData.count), "index_sha256": .string(checkpoint.indexSHA256),
            "index_pinned": true, "template_sha256": .string(runnerSHA256(checkpoint.templateBytes)),
            "shards": .count(checkpoint.inventory.shards.count),
            "tensors": .count(checkpoint.inventory.entries.count),
            "mtp_tensors": .count(checkpoint.inventory.entries(for: .mtp).count),
            "fp16_kv_bytes_per_token": .bytes(checkpoint.fp16KVBytesPerToken),
            "eos_token_ids": .array(checkpoint.eosTokenIDs.sorted().map { .count($0) }),
        ]
    }
}
