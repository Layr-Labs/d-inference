import Foundation

/// Closed short parity command. No byte/reserve, arithmetic, cut or repeat knob.
struct QwenDenseShortParityCLI {
    static let mode = "qwen-dense-short-parity-check"
    let directory: URL, promptFile: URL, teacherFile: URL
    let model: QwenRegisteredDenseModel, promptSHA256: String, teacherSHA256: String
    let timeoutSeconds: Int

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.indices.dropLast().contains { arguments[$0] == "--mode" && arguments[$0 + 1] == mode }
    }

    init(arguments: [String]) throws {
        let allowed = Set(["--mode", "--model-dir", "--registered-dense-profile", "--tokens-file",
            "--tokens-sha256", "--teacher-tokens-file", "--teacher-tokens-sha256", "--timeout-seconds"])
        guard arguments.count == 16 else { throw ProbeError("Short parity requires exactly eight named argument pairs") }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), values[key] == nil, !value.isEmpty else {
                throw ProbeError("Short parity argument is unknown, duplicated or empty")
            }
            values[key] = value
        }
        func path(_ key: String) throws -> URL {
            guard let value = values[key], value.hasPrefix("/"), !value.utf8.contains(0),
                  value.utf8.count <= 4096 else { throw ProbeError("Short parity requires bounded absolute paths") }
            return URL(fileURLWithPath: value, isDirectory: key == "--model-dir")
        }
        guard Set(values.keys) == allowed, values["--mode"] == Self.mode,
              let raw = values["--registered-dense-profile"], let model = QwenRegisteredDenseModel(rawValue: raw),
              let prompt = values["--tokens-sha256"], QwenDenseProfileIdentity.isSHA256(prompt),
              let teacher = values["--teacher-tokens-sha256"], QwenDenseProfileIdentity.isSHA256(teacher),
              let rawTimeout = values["--timeout-seconds"], rawTimeout.utf8.allSatisfy({ (48...57).contains($0) }),
              let timeout = Int(rawTimeout), (1...300).contains(timeout), String(timeout) == rawTimeout else {
            throw ProbeError("Short parity mode, profile, raw input pins or timeout differs")
        }
        directory = try path("--model-dir"); promptFile = try path("--tokens-file")
        teacherFile = try path("--teacher-tokens-file")
        self.model = model; promptSHA256 = prompt; teacherSHA256 = teacher; timeoutSeconds = timeout
    }
}
