import Cmlx
import MLX

enum Gemma4MTPPullNativeFence {
    /// Both statuses are observed even if the first fails. A failure is never a
    /// release proof; the service keeps roots and the original parent retires it.
    static func join(check: () throws -> Void) throws {
        let gpu = StreamOrDevice.gpu, cpu = StreamOrDevice.cpu
        let gpuStatus = mlx_synchronize(gpu.ctx)
        let cpuStatus = mlx_synchronize(cpu.ctx)
        try check()
        guard gpuStatus == 0, cpuStatus == 0 else { throw ProbeError("Remote MTP native completion failed: GPU=\(gpuStatus), CPU=\(cpuStatus)") }
    }
}
