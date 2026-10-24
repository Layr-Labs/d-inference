import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterWorker

struct QwenTensorMTPStartupTests {
    private func arguments(model: String = "registered_qwen38_27b", cut: Int = 16, rank: Int = 0) -> [String] {
        ["--model-dir", "/fixture/model", "--rank", String(rank), "--stage-cut", String(cut),
         "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", model,
         "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
         "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
         "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
         "--deadline-uptime-nanoseconds", "120000000100"]
    }
    @Test func typedTensorDepthIsExactModelKeyedOptInOnBothRanks() throws {
        for rank in [0, 1] {
            let plain = arguments(rank: rank) + ["--generation-mode", "tensor_parallel_v1"]
            #expect(try WorkerConfiguration(arguments: plain, now: 100).speculativeTerms == nil)
            let keyed = plain + ["--data-plane", "encrypted_v1"]
            #expect(try WorkerConfiguration(arguments: keyed, now: 100).speculativeTerms == nil)
            for depth in 1...4 {
                let value = try WorkerConfiguration(arguments: keyed + ["--mtp-depth", String(depth)], now: 100)
                #expect(value.generationMode == .tensorParallel && value.speculativeTerms?.depth == depth)
                #expect(value.dataPlaneEncrypted && value.load.rank == rank && value.tensorShares == [1, 1])
                #expect(throws: (any Error).self) {
                    try WorkerConfiguration(arguments: plain + ["--mtp-depth", String(depth)], now: 100)
                }
            }
            for value in ["0", "5", "04", "-1", "x", String(Int.max)] {
                #expect(throws: (any Error).self) {
                    try WorkerConfiguration(arguments: keyed + ["--mtp-depth", value], now: 100)
                }
            }
            #expect(throws: (any Error).self) {
                try WorkerConfiguration(arguments: keyed + ["--mtp-depth", "2", "--mtp-depth", "3"], now: 100)
            }
        }
        for (model, cut) in [("registered_qwen35_9b", 8), ("registered_qwen35_35b_a3b", 8),
                             ("registered_glm53_flash", 16)] {
            #expect(throws: (any Error).self) {
                try WorkerConfiguration(arguments: arguments(model: model, cut: cut)
                    + ["--generation-mode", "tensor_parallel_v1", "--data-plane", "encrypted_v1", "--mtp-depth", "1"], now: 100)
            }
        }
        for mode in ["pipeline_mtp_v1", "phase_split_mtp_v1"] {
            #expect(try WorkerConfiguration(arguments: arguments() + ["--generation-mode", mode, "--mtp-depth", "2"], now: 100)
                .speculativeTerms?.depth == 2)
        }
        #expect(throws: (any Error).self) {
            try WorkerConfiguration(arguments: arguments() + ["--mtp-depth", "2"], now: 100)
        }
    }
}
