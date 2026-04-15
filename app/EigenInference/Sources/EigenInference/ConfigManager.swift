/// ConfigManager — Reads and writes the same provider.toml that the Rust CLI uses.
///
/// The config file lives at `~/Library/Application Support/eigeninference/provider.toml`
/// (macOS `dirs::config_dir()` equivalent). Both the app and CLI read/write this
/// file, ensuring a single source of truth for all provider configuration.
///
/// TOML structure:
///   [provider]
///   name = "eigeninference-mac16-1"
///   memory_reserve_gb = 4
///
///   [backend]
///   port = 8100
///   model = "mlx-community/Qwen3.5-4B-4bit"
///   continuous_batching = true
///   enabled_models = []
///   backend_type = "vllm_mlx"   # vllm_mlx | mlx_lm | omlx | vmlx (default: vllm_mlx)
///
///   [coordinator]
///   url = "wss://api.darkbloom.dev/ws/provider"
///   heartbeat_interval_secs = 30

import Foundation

struct ProviderConfig: Equatable {
    var providerName: String
    var memoryReserveGB: Int

    var backendPort: Int
    var backendModel: String?
    var continuousBatching: Bool
    var enabledModels: [String]
    /// Inference backend: "vllm_mlx" (default), "mlx_lm", "omlx", or "vmlx".
    var backendType: String?

    var coordinatorURL: String
    var heartbeatIntervalSecs: Int

    static let `default` = ProviderConfig(
        providerName: "darkbloom",
        memoryReserveGB: 4,
        backendPort: 8100,
        backendModel: nil,
        continuousBatching: true,
        enabledModels: [],
        backendType: nil,
        coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
        heartbeatIntervalSecs: 30
    )
}

enum ConfigManager {

    static var configPath: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("eigeninference")
            .appendingPathComponent("provider.toml")
    }

    static var eigeninferenceDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
    }

    static func load() -> ProviderConfig {
        guard FileManager.default.fileExists(atPath: configPath.path),
              let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return .default
        }
        return parse(content)
    }

    static func save(_ config: ProviderConfig) throws {
        let dir = configPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = serialize(config)
        try toml.write(to: configPath, atomically: true, encoding: .utf8)
    }

    /// Update a single field in the config without touching others.
    static func update(_ transform: (inout ProviderConfig) -> Void) throws {
        var config = load()
        transform(&config)
        try save(config)
    }

    // MARK: - TOML Parsing

    /// Parse the provider.toml format used by the Rust CLI.
    /// Handles only the specific structure we use — not a general TOML parser.
    static func parse(_ content: String) -> ProviderConfig {
        var config = ProviderConfig.default

        var currentSection = ""
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)

            let value = unquote(rawValue)

            switch currentSection {
            case "provider":
                switch key {
                case "name": config.providerName = value
                case "memory_reserve_gb": config.memoryReserveGB = Int(value) ?? 4
                default: break
                }

            case "backend":
                switch key {
                case "port": config.backendPort = Int(value) ?? 8100
                case "model":
                    let m = value.isEmpty ? nil : value
                    config.backendModel = m
                case "continuous_batching": config.continuousBatching = (value == "true")
                case "enabled_models": config.enabledModels = parseArray(rawValue)
                case "backend_type": config.backendType = value.isEmpty ? nil : value
                default: break
                }

            case "coordinator":
                switch key {
                case "url": config.coordinatorURL = value
                case "heartbeat_interval_secs":
                    config.heartbeatIntervalSecs = Int(value) ?? 30
                default: break
                }

            default: break
            }
        }

        return config
    }

    /// Serialize config back to TOML matching the Rust CLI format exactly.
    static func serialize(_ config: ProviderConfig) -> String {
        var lines: [String] = []

        lines.append("[provider]")
        lines.append("name = \(quote(config.providerName))")
        lines.append("memory_reserve_gb = \(config.memoryReserveGB)")
        lines.append("")

        lines.append("[backend]")
        lines.append("port = \(config.backendPort)")
        if let model = config.backendModel {
            lines.append("model = \(quote(model))")
        }
        lines.append("continuous_batching = \(config.continuousBatching)")
        let modelsArray = config.enabledModels.map { quote($0) }.joined(separator: ", ")
        lines.append("enabled_models = [\(modelsArray)]")
        if let bt = config.backendType {
            lines.append("backend_type = \(quote(bt))")
        }
        lines.append("")

        lines.append("[coordinator]")
        lines.append("url = \(quote(config.coordinatorURL))")
        lines.append("heartbeat_interval_secs = \(config.heartbeatIntervalSecs)")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
            v = v.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }

    private static func parseArray(_ raw: String) -> [String] {
        guard let open = raw.firstIndex(of: "["),
              let close = raw.lastIndex(of: "]") else { return [] }
        let inner = String(raw[raw.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return inner.components(separatedBy: ",").map {
            unquote($0.trimmingCharacters(in: .whitespaces))
        }
    }
}
