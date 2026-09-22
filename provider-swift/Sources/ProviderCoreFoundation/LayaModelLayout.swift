import Foundation

/// Recognizes the native decision checkpoint without inventing a chat configuration.
/// This is an artifact-format capability, independent of the catalog model ID.
public enum LayaModelLayout {
    /// Does not require the complete runtime configuration to validate: even a
    /// corrupt agent configuration remains part of this format's attested bytes.
    public static func integrityMetadataFiles(at directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("mlx_config.json")),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            json["format"] as? String == "laya-mlx" else { return [] }
        return ["mlx_config.json", "rl_agent_config.json", "LICENSE", "NOTICE"]
    }

    public static func isSupported(at directory: URL) -> Bool {
        func object(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let format = object("mlx_config.json"),
            format["format"] as? String == "laya-mlx",
            format["format_version"] as? Int == 1,
            format["dtype"] as? String == "float16",
            let encoder = object("encoder/config.json"),
            encoder["model_type"] as? String == "modernbert",
            let agent = object("rl_agent_config.json"),
            agent["head_layers"] as? Int == 2,
            agent["max_len"] as? Int == 512,
            agent["head_max_len"] as? Int == 192,
            agent["max_prefixes"] as? Int == 6 else { return false }
        return ["model.safetensors", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}
