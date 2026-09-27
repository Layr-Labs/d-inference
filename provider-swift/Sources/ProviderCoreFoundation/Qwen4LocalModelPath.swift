import Foundation

/// Explicit isolated staging for one owned model. This selects a directory;
/// scanner, artifact hashing, model admission and native loading still run.
public enum Qwen4LocalModelPath {
    public static let environmentKey = "DARKBLOOM_QWEN4_MODEL_PATH"

    public static func isConfigured(environment: [String: String]) -> Bool {
        environment[environmentKey] != nil
    }

    public static func directory(environment: [String: String]) -> URL? {
        guard let path = environment[environmentKey], path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let config = object(at: directory.appendingPathComponent("config.json")),
            ModelMediaPolicy.isNativeQwen4Type(config["model_type"] as? String),
            let index = object(at: directory.appendingPathComponent("model.safetensors.index.json")),
            let weights = index["weight_map"] as? [String: String], !weights.isEmpty,
            weights.values.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0.hasSuffix(".safetensors") })
        else { return nil }
        return directory
    }

    private static func object(at file: URL) -> [String: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 16 * 1024 * 1024,
            let data = try? Data(contentsOf: file),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return value
    }
}
