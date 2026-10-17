import Foundation

final class FixtureChecks {
    private(set) var accepted: [String] = []
    private(set) var rejected: [String] = []

    func require(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { throw ProbeError("Fixture failed: " + name) }
        accepted.append(name)
    }

    func refuses(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Fixture accepted: " + name)
    }
}

struct FixtureInputs {
    let root: URL
    let configuration: Data
    let manifest: Data
    let index: Data
    let headers: [LayerStageCapturedTensorHeader]
    let artifact: Gemma4ArtifactMetadata

    init(root: URL) throws {
        self.root = root
        configuration = try Self.read(root, "config.json")
        manifest = try Self.read(root, "manifest.json")
        index = try Self.read(root, "model.safetensors.index.json")
        headers = try (1...3).map { number in
            let file = String(format: "model-%05d-of-00003.safetensors", number)
            return LayerStageCapturedTensorHeader(sourceFile: file, data: try Self.read(root, file + ".header.json"))
        }
        artifact = try Gemma4ArtifactMetadata.admit(configuration: configuration, manifest: manifest, index: index, headers: headers)
    }

    static func read(_ root: URL, _ name: String) throws -> Data {
        try BoundedProbeInput.data(root.appendingPathComponent(name), maximumBytes: 2_097_152)
    }

    func changedJSON(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeError("Fixture object missing") }
        change(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
