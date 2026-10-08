import MLX
import Testing

/// The same encrypted-store witness using tiny CPU tensors. This is storage /
/// publication evidence, not GPU inference, paged adoption or model qualification.
/// No engine/model/server is loaded and the existing GPU witness is unchanged.
@Suite("CPU checkpoint publication regression", .serialized)
struct SSDCheckpointPublicationCPUTests {
    @Test("same-store eviction preserves readable bytes and publication")
    func cpuStoragePublication() async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            // This fixture is contiguous. Its source reshape/eval and native
            // import destination allocations use StreamOrDevice.default. The
            // enclosing task-local CPU device survives the stage's awaits;
            // the write queue reads already evaluated CPU source buffers.
            try await SSDCheckpointPublicationTests().survivingWriteKeepsReady()
            #expect(Device.defaultDevice().deviceType == .cpu)
            print("CACHE_DIAGNOSTIC_CPU default_device=cpu model_loaded=false contiguous_fixture=true")
        }
    }
}
