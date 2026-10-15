import Foundation
import MLX

#if CBV2_WINDOW_STATE_FIXTURE
enum Gemma4MTPStateQualification {
    static func run(input: Gemma4BenchmarkInput, check: () throws -> Void) throws -> Data {
        guard input.job.rank == nil, !input.job.captureEvidence else {
            throw ProbeError("MTP state qualification requires one full role and no model evidence captures")
        }
        return try withoutActuallyEscaping(check) { outer in
            try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                setCacheLimit: { Memory.cacheLimit = $0 }, check: outer)
            Memory.clearCache(); try outer()
            let baseline = Memory.activeMemory
            func checked() throws {
                try outer()
                let os = try QwenResidentResourceEnvironment.observe()
                let native = QwenDenseStageLoadResources.observeNative()
                let reserve = 64 * 1024 * 1024
                let sum = QwenLongPrefillCheckedBytes.sum
                guard os.pressureLevel == 1,
                      os.actualFreeBytes >= 10 * 1024 * 1024 * 1024 + reserve,
                      native.activeBytes >= baseline, native.activeBytes <= baseline + reserve,
                      native.cacheBytes == 0,
                      try sum([native.activeBytes, reserve, 2 * 1024 * 1024 * 1024]) <= native.allocatorLimitBytes else {
                    throw ProbeError("Tiny MTP state qualification exceeds its unchanged resource headroom")
                }
            }
            let bytes = try AttentionTargetVerificationCheck.run(check: checked)
            try checked()
            guard var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw ProbeError("MTP state qualification omitted its result")
            }
            result["schema"] = "gemma4_owned_mtp_state_qualification_v1"
            result["job"] = try JSONSerialization.jsonObject(with: canonicalJSONData(input.job))
            result["scopeSHA256"] = input.scopeSHA256
            result["throughputMeasured"] = false
            result["actualFreeHeadroomRequiredBytes"] = 10 * 1024 * 1024 * 1024 + 64 * 1024 * 1024
            result["allocatorHeadroomRequiredBytes"] = 2 * 1024 * 1024 * 1024
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
    }
}
#endif
