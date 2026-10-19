import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Placement configuration read limits", .serialized)
struct ClusterPlacementArtifactBoundsTests {
    private func withConfiguration(_ data: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("config.json"))
        try body(directory)
    }

    private func configuration(bytes: Int, modelType: String = "glm5_next") -> Data {
        var data = Data("{\"model_type\":\"\(modelType)\"}".utf8)
        data.append(Data(repeating: 32, count: bytes - data.count))
        return data
    }

    @Test(arguments: [10_023_646, 32 * 1024 * 1024])
    func largerConfigurationIsReadExactlyThroughTheBound(bytes: Int) throws {
        let expected = configuration(bytes: bytes)
        try withConfiguration(expected) { directory in
            let actual = try ClusterPlacementArtifact.configuration(directory: directory)
            #expect(actual == expected)
            // Merely fitting the IO bound cannot make a configuration registered.
            let context = try ClusterPlacementArtifact.requestedContext(directory: directory, contextTokens: 32)
            #expect(context == nil)
            #expect(throws: QwenDenseProfileError.self) { try QwenDensePlacementFamily(configuration: expected) }
        }
    }

    @Test func emptyAndOneByteOverLimitAreRejectedByBothEntryPoints() throws {
        for data in [Data(), configuration(bytes: 32 * 1024 * 1024 + 1)] {
            try withConfiguration(data) { directory in
                #expect(throws: ProbeError.self) { try ClusterPlacementArtifact.configuration(directory: directory) }
                #expect(throws: ProbeError.self) {
                    try ClusterPlacementArtifact.requestedContext(directory: directory, contextTokens: 32)
                }
                #expect(throws: ProbeError.self) { try ClusterPlacementArtifact.layout(directory: directory) }
            }
        }
    }

    @Test(arguments: [128, 10_023_646])
    func unknownArchitectureStillCannotProduceALayout(bytes: Int) throws {
        try withConfiguration(configuration(bytes: bytes, modelType: "unsupported_fixture")) { directory in
            // Supply a valid tiny shard so refusal comes from architecture
            // dispatch rather than a missing-file or malformed-header check.
            let header = Data(#"{"fixture.weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
            var length = UInt64(header.count).littleEndian
            var shard = Data(bytes: &length, count: 8)
            shard.append(header); shard.append(Data(repeating: 0, count: 4))
            try shard.write(to: directory.appendingPathComponent("model.safetensors"))
            let tensors = try ClusterPlacementArtifact.storedTensors(directory: directory)
            #expect(tensors.count == 1)
            #expect(throws: QwenDenseProfileError.self) { try ClusterPlacementArtifact.layout(directory: directory) }
            let context = try ClusterPlacementArtifact.requestedContext(directory: directory, contextTokens: 32)
            #expect(context == nil)
        }
    }
}
