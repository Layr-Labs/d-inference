import XCTest
@testable import ProviderCoreFoundation

/// Locks the property that the aggregate hash is independent of the order in
/// which files were created on disk. We build the same logical fixture twice,
/// once in alphabetical order and once in reverse, and assert the two
/// manifests produce the same aggregate.
final class EnumerationOrderInvarianceTest: XCTestCase {

    func testOrderIndependence() async throws {
        let aDir = try makeFixture(reversed: false)
        let bDir = try makeFixture(reversed: true)
        defer {
            try? FileManager.default.removeItem(at: aDir)
            try? FileManager.default.removeItem(at: bDir)
        }

        let a = try await ManifestBuilder.build(modelDirectory: aDir, modelID: "test/order", version: "v1")
        let b = try await ManifestBuilder.build(modelDirectory: bDir, modelID: "test/order", version: "v1")

        XCTAssertEqual(a.aggregateSHA256, b.aggregateSHA256,
            "Aggregate hash depends on filesystem enumeration order; sorting is broken.")
        XCTAssertEqual(a.files.map { $0.path }, b.files.map { $0.path },
            "File order in manifest depends on filesystem enumeration order.")
        XCTAssertEqual(a.fileCount, b.fileCount)
        XCTAssertEqual(a.totalSizeBytes, b.totalSizeBytes)
    }

    /// Build a fixture with several files. The contents are deterministic and
    /// keyed off filename, so two fixtures built with different creation
    /// orders are logically equivalent.
    private func makeFixture(reversed: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbpub-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let textFiles: [(String, String)] = [
            ("config.json", "alpha"),
            ("tokenizer.json", "bravo"),
            ("tokenizer_config.json", "charlie"),
            ("special_tokens_map.json", "delta"),
            ("generation_config.json", "echo"),
        ]
        let weightFiles: [(String, UInt8)] = [
            ("model-00001-of-00002.safetensors", 0x11),
            ("model-00002-of-00002.safetensors", 0x22),
        ]

        var actions: [() throws -> Void] = []
        for (name, content) in textFiles {
            actions.append {
                try content.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        for (name, byte) in weightFiles {
            actions.append {
                try Data(repeating: byte, count: 24).write(to: url.appendingPathComponent(name))
            }
        }
        if reversed {
            actions.reverse()
        }
        for action in actions { try action() }
        return url
    }
}
