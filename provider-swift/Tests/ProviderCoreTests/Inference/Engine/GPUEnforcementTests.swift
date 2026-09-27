// Unit tests for `GPUEnforcement`.
//
// The helper is intentionally tiny -- a Metal probe + a `Device.setDefault`
// pin -- but it gates every model load, so a regression here would silently
// fall back to CPU and tank inference performance. These tests run on every
// CI machine (the host runner has Metal available) and lock in:
//
//   1. `probeMetal()` reports a non-nil device name on Apple Silicon.
//   2. `requireMetal()` succeeds and returns a populated `MetalStatus`.
//   3. After `requireMetal()`, MLX's default device is GPU.
//   4. The error type's `description` is informative enough to debug
//      a CPU-fallback scenario without grepping source.

import Foundation
import MLX
import Testing
@testable import ProviderCore

@Suite("GPUEnforcement")
struct GPUEnforcementTests {

    @Test("probeMetal reports an available Metal device on this host")
    func probeMetalIsAvailable() {
        let status = GPUEnforcement.probeMetal()
        // CI runners and developer Macs are Apple Silicon; if this fires
        // we're either on Linux/x86 (don't run tests there) or the Metal
        // toolchain isn't linked.
        #expect(status.isAvailable, "Metal device probe failed; expected an Apple Silicon GPU")
        #expect(status.deviceName != nil, "probe must surface device name when available")
        #expect(status.recommendedMaxWorkingSetSizeBytes > 0, "working set should be positive")
    }

    @Test("requireMetal restores a CPU-planted default back to GPU (child process)")
    func requireMetalPinsGPU() async {
        // MLX's default device is PROCESS-GLOBAL, and swift-testing runs
        // suites in parallel inside ONE process. This test used to plant
        // `Device.setDefault(device: .cpu)` inline to prove requireMetal()
        // restores GPU — and in the window before the restore, any
        // concurrently-running suite that dispatched a GPU-only Metal kernel
        // died with `[metal_kernel] Only supports the GPU` → fatalError →
        // SIGTRAP, killing the whole test process (observed live as a flake
        // attributed to whichever suite happened to be mid-dispatch).
        // `.serialized` cannot fix that: it serializes within a suite, never
        // across suites sharing the process, and the CPU plant's blast
        // radius is exactly cross-suite.
        //
        // The assertion is worth keeping in its strong form — "requireMetal
        // RESTORES gpu from a planted cpu default", not merely "gpu stays
        // gpu" — so the plant runs in a CHILD process via an exit test. The
        // child owns its global device; the parent process never leaves GPU.
        await #expect(processExitsWith: .success) {
            Device.setDefault(device: .cpu)
            _ = try GPUEnforcement.requireMetal()
            #expect(
                Device.defaultDevice().deviceType == .gpu,
                "default device must be GPU after requireMetal()")
        }
    }

    @Test("requireMetal is idempotent")
    func requireMetalIdempotent() throws {
        _ = try GPUEnforcement.requireMetal()
        _ = try GPUEnforcement.requireMetal()
        #expect(Device.defaultDevice().deviceType == .gpu)
    }

    @Test("error description names the failure mode clearly")
    func errorDescriptionMentionsCPUFallback() {
        let err = GPUEnforcement.Error.metalUnavailable
        let desc = String(describing: err)
        #expect(desc.contains("GPU"), "error must mention GPU")
        #expect(desc.contains("CPU"), "error must mention the rejected CPU fallback")
    }
}
