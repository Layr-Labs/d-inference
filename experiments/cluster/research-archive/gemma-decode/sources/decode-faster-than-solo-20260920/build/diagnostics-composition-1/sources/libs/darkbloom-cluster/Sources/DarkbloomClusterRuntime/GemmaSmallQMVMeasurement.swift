import Cmlx
import Foundation
import MLX

/// Timings include fresh graph creation, actual eval and checked C stream
/// completion. Fresh environment guards bracket each sample outside its timer.
/// Copies/comparison are outside timing; no throughput/model claim is made.
enum GemmaSmallQMVMeasurement {
    struct Sample { let nanos: UInt64, bytes: Data, finite: Bool, values: [Float] }
    static func fence(native: () throws -> Void) throws {
        let gpu = mlx_synchronize(StreamOrDevice.gpu.ctx)
        let cpu = mlx_synchronize(StreamOrDevice.cpu.ctx)
        try native()
        guard gpu == 0, cpu == 0 else { throw ProbeError("Small QMV completion fence failed") }
    }
    static func sample(check: () throws -> Void, native: () throws -> Void,
                       make: () throws -> [MLXArray]) throws -> Sample {
        try check()
        let begin = DispatchTime.now().uptimeNanoseconds
        let arrays = try make(); try native()
        eval(arrays); try native()
        try fence(native:native)
        let end = DispatchTime.now().uptimeNanoseconds
        try check()
        var bytes = Data(), finite = true
        var allValues: [Float] = []
        for array in arrays {
            bytes.append(array.asData(access:.copy).data); try check()
            let values = array.asType(.float32).asArray(Float.self); try check()
            finite = finite && values.allSatisfy(\.isFinite); allValues += values
        }
        return Sample(nanos:end-begin,bytes:bytes,finite:finite,values:allValues)
    }
    static func compare(label: String, metadata: [String:Any], check: () throws -> Void,
                        native: () throws -> Void, reference: () throws -> [MLXArray],
                        candidate: () throws -> [MLXArray], ordinaryBatch: (() throws -> [MLXArray])? = nil
    ) throws -> [String:Any] {
        var refTimes: [UInt64] = [], candidateTimes: [UInt64] = [], batchTimes: [UInt64] = []
        var exact = true, finite = true, batchExact = true, maxDifferentBytes = 0
        var referenceHash = "", candidateHash = "", batchHash = ""
        var batchMaxAbs = 0.0, batchRelativeRMS = 0.0
        for trial in 0..<4 { // one warmup and three paired measurements
            let a: Sample, b: Sample
            if trial%2 == 0 {
                a = try autoreleasepool { try sample(check:check,native:native,make:reference) }
                b = try autoreleasepool { try sample(check:check,native:native,make:candidate) }
            } else {
                b = try autoreleasepool { try sample(check:check,native:native,make:candidate) }
                a = try autoreleasepool { try sample(check:check,native:native,make:reference) }
            }
            exact = exact && a.bytes == b.bytes
            finite = finite && a.finite && b.finite
            guard a.bytes.count == b.bytes.count else { throw ProbeError("Small QMV output byte count differs") }
            maxDifferentBytes = max(maxDifferentBytes,zip(a.bytes,b.bytes).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) })
            referenceHash = sha256(a.bytes); candidateHash = sha256(b.bytes)
            if trial > 0 { refTimes.append(a.nanos); candidateTimes.append(b.nanos) }
            if let ordinaryBatch {
                let c = try autoreleasepool { try sample(check:check,native:native,make:ordinaryBatch) }
                guard c.bytes.count == a.bytes.count else { throw ProbeError("Current dense batch size differs") }
                batchExact = batchExact && a.bytes == c.bytes && c.finite; batchHash = sha256(c.bytes)
                var square = 0.0, norm = 0.0
                for (left,right) in zip(a.values,c.values) {
                    guard left.isFinite, right.isFinite else { throw ProbeError("Nonfinite ordinary dense result") }
                    let delta = Double(left)-Double(right)
                    batchMaxAbs = max(batchMaxAbs,abs(delta)); square += delta*delta; norm += Double(left)*Double(left)
                }
                batchRelativeRMS = max(batchRelativeRMS,sqrt(square/max(norm,1e-30)))
                if trial > 0 { batchTimes.append(c.nanos) }
            }
        }
        var row = metadata
        row["name"] = label; row["passed"] = exact && finite; row["exactOutputBytes"] = exact
        row["finite"] = finite; row["maximumDifferentBytes"] = maxDifferentBytes
        row["referenceSHA256"] = referenceHash; row["candidateSHA256"] = candidateHash
        row["referenceNanoseconds"] = refTimes; row["candidateNanoseconds"] = candidateTimes
        if ordinaryBatch != nil {
            row["currentBatchExactToM1"] = batchExact; row["currentBatchSHA256"] = batchHash
            row["currentBatchNanoseconds"] = batchTimes
            row["currentBatchMaximumAbsoluteError"] = batchMaxAbs
            row["currentBatchMaximumRelativeRMSError"] = batchRelativeRMS
        }
        return row
    }
}
