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

    @Test("requireMetal pins MLX default device to GPU")
    func requireMetalPinsGPU() throws {
        // Even if some other test has set CPU as default, requireMetal()
        // must restore GPU.
        Device.setDefault(device: .cpu)
        _ = try GPUEnforcement.requireMetal()
        #expect(Device.defaultDevice().deviceType == .gpu, "default device must be GPU after requireMetal()")
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
