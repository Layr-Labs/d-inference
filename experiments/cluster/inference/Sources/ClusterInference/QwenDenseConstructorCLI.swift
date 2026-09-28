import Foundation
import Darwin

/// Deliberately separate from Options: this exact constructor-only mode cannot
/// inherit prefill, tracing, distributed, source-override or materializer flags.
struct QwenDenseConstructorCLI {
    static let mode = "qwen-dense-constructor-check"
    let directory: URL, model: QwenRegisteredDenseModel, timeoutSeconds: Int

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.indices.dropLast().contains { arguments[$0] == "--mode" && arguments[$0 + 1] == mode }
    }

    init(arguments: [String]) throws {
        let allowed = Set(["--mode", "--model-dir", "--registered-dense-profile", "--timeout-seconds"])
        guard arguments.count == 8 else { throw ProbeError("Constructor probe requires exactly four named argument pairs") }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), values[key] == nil, !value.isEmpty else {
                throw ProbeError("Constructor probe argument is unknown, duplicated or empty")
            }
            values[key] = value
        }
        guard Set(values.keys) == allowed, values["--mode"] == Self.mode,
              let path = values["--model-dir"], path.hasPrefix("/"), !path.utf8.contains(0),
              let rawModel = values["--registered-dense-profile"],
              let model = QwenRegisteredDenseModel(rawValue: rawModel),
              let rawTimeout = values["--timeout-seconds"], !rawTimeout.isEmpty,
              rawTimeout.utf8.allSatisfy({ (48...57).contains($0) }),
              let timeout = Int(rawTimeout), (1...300).contains(timeout), String(timeout) == rawTimeout else {
            throw ProbeError("Constructor probe mode, absolute directory, profile or bounded timeout differs")
        }
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        self.model = model; self.timeoutSeconds = timeout
    }

}
