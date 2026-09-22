import Foundation

public struct OllamaModel: Codable, Identifiable, Sendable, Equatable {
    public let name: String
    public let digest: String
    public let size: Int64
    public let details: Details?
    public var id: String { name + ":" + digest }
    public struct Details: Codable, Sendable, Equatable {
        public let format: String?
        public let family: String?
        public let parameter_size: String?
        public let quantization_level: String?
    }
}

public struct OllamaInventory: Sendable {
    public var models: [OllamaModel]
    public var runningNames: Set<String>
    public var source: String
    public var reachable: Bool
}

public enum OllamaDiscovery {
    public static func decode(_ data: Data) throws -> [OllamaModel] {
        struct Envelope: Decodable { let models: [OllamaModel] }
        guard data.count <= 1_048_576 else { throw ConnectError.oversized }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.models.count <= 256 else { throw ConnectError.oversized }
        var seen = Set<String>()
        return envelope.models.filter {
            !$0.name.isEmpty && $0.name.utf8.count <= 200 && !$0.name.unicodeScalars.contains(where: { $0.value < 32 })
                && $0.size >= 0 && $0.digest.utf8.count <= 128 && seen.insert($0.id).inserted
        }
    }

    public static func discover() async -> OllamaInventory {
        do {
            let models = try decode(await MetadataClient().get(.ollamaModels))
            let running = (try? decode(await MetadataClient().get(.ollamaRunning))) ?? []
            return .init(models: models, runningNames: Set(running.map(\.name)), source: "Ollama local API", reachable: true)
        } catch {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models/manifests")
            let models = diskModels(at: root)
            return .init(models: models, runningNames: [], source: models.isEmpty ? "Ollama not found" : "Saved Ollama library · app offline", reachable: false)
        }
    }

    /// Names and manifests are discovery hints only. They never select an
    /// executable, catalog identity, download URL, or serving permission.
    static func diskModels(at root: URL) -> [OllamaModel] {
        let fm = FileManager.default
        var pending: [(URL, Int)] = [(root, 0)]
        var visited = 0
        var result: [OllamaModel] = []
        while let (directory, depth) = pending.popLast(), visited < 1024, result.count < 256 {
            guard depth < 5,
                  let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries.prefix(256) {
                guard visited < 1024, result.count < 256 else { break }
                visited += 1
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { pending.append((url, depth + 1)); continue }
                guard depth == 3, let data = try? SafeFile.read(url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let layers = json["layers"] as? [[String: Any]], layers.count <= 64 else { continue }
                let size = layers.compactMap { $0["size"] as? Int64 }.filter { $0 >= 0 && $0 < 1_000_000_000_000 }.reduce(Int64(0), +)
                let parts = Array(url.pathComponents.suffix(4))
                let namespace = parts[1] == "library" ? "" : parts[1] + "/"
                let registry = parts[0] == "registry.ollama.ai" ? "" : parts[0] + "/"
                let name = registry + namespace + parts[2] + ":" + parts[3]
                guard name.utf8.count <= 200, !name.unicodeScalars.contains(where: { $0.value < 32 }) else { continue }
                result.append(.init(name: name, digest: "disk-inventory", size: size,
                                    details: nil))
            }
        }
        return result.sorted { $0.name < $1.name }
    }
}
