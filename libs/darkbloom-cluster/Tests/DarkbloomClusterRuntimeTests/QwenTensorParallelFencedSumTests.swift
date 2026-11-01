import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// The Qwen tensor-parallel residual step reads its FP32 all-sum as a fenced
/// input (`ResidualRMSNorm`): when the sum comes from the CPU stream in the
/// same evaluation (as the collective's sealed sum does), the kernel waits
/// for the CPU itself instead of MLX's separate fence-wait launch.
/// Synchronization only, so every result must be bitwise the result of the
/// same step on the already evaluated sum, and a chain of such hops must not
/// hang. The GPU checks are opt-in (`QWEN_TP_AQV_GPU=1`); run them with
/// `MLX_METAL_FAST_SYNCH=1 MLX_METAL_FENCED_INPUTS=1` for the kernel-side
/// waits, and without for the existing fences.
@Suite(.serialized)
struct QwenTensorParallelFencedSumTests {
    static var gpu: Bool { ProcessInfo.processInfo.environment["QWEN_TP_AQV_GPU"] == "1" }

    private static var mode: String {
        let environment = ProcessInfo.processInfo.environment
        return ["MLX_METAL_FAST_SYNCH", "MLX_METAL_FENCED_INPUTS"]
            .map { "\($0)=\(environment[$0] ?? "0")" }.joined(separator: " ")
    }

    private static func bytes(_ value: MLXArray) -> Data { eval(value); return value.asData(access: .copy).data }

    /// The families whose tensor-parallel kernels read every sum as a fenced
    /// input, so their ranks wait in the reading kernel (`WorkerFenceFusion`).
    @Test func familiesThatReadTheirSumsAsFencedInputs() {
        #expect(ClusterResidentModelCatalog.Family.qwenDense.tensorParallelSumsAreFencedInputs)
        #expect(ClusterResidentModelCatalog.Family.glm5Next.tensorParallelSumsAreFencedInputs)
        #expect(!ClusterResidentModelCatalog.Family.gptoss.tensorParallelSumsAreFencedInputs)
        #expect(!ClusterResidentModelCatalog.Family.mimoV26.tensorParallelSumsAreFencedInputs)
    }

    /// Both ranks bind the waits they resolved (and the projections) into the
    /// load agreement; the line each rank logs carries the same choice.
    @Test func theLoadAgreementBindsTheFencedSums() {
        let fields = QwenTensorParallelBatchSession.decodeAgreementFields
        let index = fields.firstIndex(of: "qwen-tensor-parallel-fenced-sums-v1")
        #expect(index != nil && index! + 1 < fields.count)
        #expect(index.map { fields[$0 + 1] } == (QwenTensorParallelBatchSession.sumsAreFencedInputs ? "on" : "off"))
        let environment = ProcessInfo.processInfo.environment
        let expected = environment["MLX_METAL_FENCED_INPUTS"].flatMap { Int($0) }.map { $0 != 0 } == true
            && environment["MLX_METAL_FAST_SYNCH"].flatMap { Int($0) }.map { $0 != 0 } == true
        #expect(QwenTensorParallelBatchSession.sumsAreFencedInputs == expected)
    }

    /// An FP32 "sum" made on the CPU stream, slowly (a K = 8192 matmul), so
    /// the GPU reaches the residual step long before the CPU writes it.
    private static func cpuSum(rows: Int, width: Int, seed: UInt64) -> MLXArray {
        let keys = MLXRandom.split(key: MLXRandom.key(seed), into: 2)
        let a = MLXRandom.normal([rows, 8192], key: keys[0]) * 0.02
        let b = MLXRandom.normal([8192, width], key: keys[1]) * 0.02
        eval(a, b)
        return matmul(a, b, stream: .cpu)
    }

    /// The residual step on a CPU-stream sum in the same evaluation, then on
    /// that sum once evaluated (no fence): bitwise, at every geometry and on
    /// fresh values each time (rows up to 4096 wide and the looped kernel).
    @Test(.enabled(if: Self.gpu)) func cpuStreamSumIsBitwiseOnGPU() throws {
        try Device.withDefaultDevice(.gpu) {
            for (index, geometry) in [[1, 5120], [4, 5120], [8, 4096], [3, 1000], [2, 6002]].enumerated() {
                let (rows, width) = (geometry[0], geometry[1])
                for repeat_ in 0 ..< 3 {
                    let seed = UInt64(100 * index + repeat_)
                    let keys = MLXRandom.split(key: MLXRandom.key(seed + 50), into: 2)
                    let x = (MLXRandom.normal([rows, width], key: keys[0]) * 2).asType(.bfloat16)
                    let weight = MLXRandom.uniform(low: Float(0.5), high: Float(1.5), [width], key: keys[1])
                        .asType(.bfloat16)
                    eval(x, weight)
                    let sum = Self.cpuSum(rows: rows, width: width, seed: seed)
                    let fenced = try #require(ResidualRMSNorm.apply(x, sum, weight: weight, eps: 1e-6))
                    try withError { error in
                        eval(fenced.sum, fenced.norm, sum)
                        try error.check()
                    }
                    let reference = try #require(ResidualRMSNorm.apply(x, sum, weight: weight, eps: 1e-6))
                    #expect(Self.bytes(fenced.sum) == Self.bytes(reference.sum)
                        && Self.bytes(fenced.norm) == Self.bytes(reference.norm),
                        "rows=\(rows) width=\(width) #\(repeat_) differs")
                }
                print("QWEN_TP_FENCED_SUM step rows=\(rows) width=\(width) ok \(Self.mode)")
            }
        }
    }

    /// A decode-like chain with a GPU -> CPU -> GPU hop at every residual step,
    /// as the tensor-parallel sums make: 128 steps in one evaluation, each
    /// step's next "sum" a projection of its norm copied on the CPU stream
    /// (`* 1`, exact). Bitwise to the same chain with the copy on the GPU, and
    /// it must not hang.
    @Test(.enabled(if: Self.gpu)) func chainWithCPUHopsIsBitwiseOnGPU() throws {
        try Device.withDefaultDevice(.gpu) {
            for rows in [1, 4] {
                let width = 5120
                let keys = MLXRandom.split(key: MLXRandom.key(7 + UInt64(rows)), into: 3)
                let start = (MLXRandom.normal([rows, width], key: keys[0]) * 2).asType(.bfloat16)
                let weight = MLXRandom.uniform(low: Float(0.5), high: Float(1.5), [width], key: keys[1])
                    .asType(.bfloat16)
                let mix = (MLXRandom.normal([width, width], key: keys[2]) * 0.01).asType(.bfloat16)
                let one = MLXArray(Float(1))
                eval(start, weight, mix, one)
                var finals: [[MLXArray]] = []
                for device in [StreamOrDevice.cpu, .gpu] {
                    var hidden = start
                    var sum = MLXArray.zeros([rows, width], dtype: .float32)
                    var seen: [MLXArray] = []
                    for _ in 0 ..< 128 {
                        let step = try #require(ResidualRMSNorm.apply(hidden, sum, weight: weight, eps: 1e-6))
                        hidden = step.sum
                        seen.append(step.norm)
                        sum = multiply(matmul(step.norm, mix).asType(.float32), one, stream: device)
                    }
                    finals.append([hidden] + seen)
                }
                let started = Date()
                try withError { error in
                    eval(finals[0])
                    try error.check()
                }
                let seconds = Date().timeIntervalSince(started)
                eval(finals[1])
                let differing = zip(finals[0], finals[1]).filter { Self.bytes($0) != Self.bytes($1) }.count
                #expect(differing == 0, "rows=\(rows) chain: \(differing) outputs differ")
                print("QWEN_TP_FENCED_SUM chain rows=\(rows) steps=128 cpu_hops_s=\(seconds) differing=\(differing) \(Self.mode)")
            }
        }
    }

    /// A fenced sum that is not row-contiguous is copied before the kernel, so
    /// MLX waits before the copy (the separate wait): still bitwise.
    @Test(.enabled(if: Self.gpu)) func transposedCPUSumWaitsBeforeTheCopyOnGPU() throws {
        try Device.withDefaultDevice(.gpu) {
            let (rows, width) = (3, 5120)
            let keys = MLXRandom.split(key: MLXRandom.key(31), into: 2)
            let x = (MLXRandom.normal([rows, width], key: keys[0]) * 2).asType(.bfloat16)
            let weight = MLXRandom.uniform(low: Float(0.5), high: Float(1.5), [width], key: keys[1]).asType(.bfloat16)
            eval(x, weight)
            let sum = transposed(Self.cpuSum(rows: width, width: rows, seed: 32), axes: [1, 0], stream: .cpu)
            #expect(sum.shape == [rows, width])
            let fenced = try #require(ResidualRMSNorm.apply(x, sum, weight: weight, eps: 1e-6))
            try withError { error in
                eval(fenced.sum, fenced.norm, sum)
                try error.check()
            }
            let reference = try #require(ResidualRMSNorm.apply(x, contiguous(sum), weight: weight, eps: 1e-6))
            #expect(Self.bytes(fenced.sum) == Self.bytes(reference.sum) && Self.bytes(fenced.norm) == Self.bytes(reference.norm),
                "transposed sum differs")
        }
    }
}
