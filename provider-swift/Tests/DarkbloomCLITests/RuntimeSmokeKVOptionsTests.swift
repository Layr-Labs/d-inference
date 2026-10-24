import ArgumentParser
import Testing

@testable import darkbloom

@Suite("Packaged runtime KV preflight controls")
struct RuntimeSmokeKVOptionsTests {
    @Test func defaultAndModelSpecificProfilesParse() throws {
        #expect(try RuntimeSmoke.parse([]).kvQuantization == "balanced")
        let command = try RuntimeSmoke.parse([
            "--kv-quantization", "k8v4", "--packed-shape", "64:8:64:1:0:0:bf16:bf16",
            "--packed-shape", "64:8:64:1:1024:0:f32:f32", "64:8:64:1:1",
        ])
        #expect(command.kvQuantization == "k8v4")
        #expect(command.packedShapes == ["64:8:64:1:0:0:bf16:bf16", "64:8:64:1:1024:0:f32:f32"])
        #expect(command.shapes == ["64:8:64:1:1"])
    }
}
