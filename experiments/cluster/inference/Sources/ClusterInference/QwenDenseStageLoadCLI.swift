import Foundation

/// Closed loading-only command. Metadata admission remains separate from the
/// live one-stage gate; these parsed values confer no allocation permission.
struct QwenDenseStageLoadCLI {
    static let mode = "qwen-dense-stage-load-check"
    let directory: URL, model: QwenRegisteredDenseModel, stageIndex: Int, timeoutSeconds: Int

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.indices.dropLast().contains { arguments[$0] == "--mode" && arguments[$0 + 1] == mode }
    }

    init(arguments: [String]) throws {
        let allowed = Set(["--mode", "--model-dir", "--registered-dense-profile", "--stage-index", "--timeout-seconds"])
        guard arguments.count == 10 else { throw ProbeError("Stage load requires exactly five named argument pairs") }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), values[key] == nil, !value.isEmpty else {
                throw ProbeError("Stage load argument is unknown, duplicated or empty")
            }
            values[key] = value
        }
        guard Set(values.keys) == allowed, values["--mode"] == Self.mode,
              let path = values["--model-dir"], path.hasPrefix("/"), !path.utf8.contains(0),
              let rawModel = values["--registered-dense-profile"], let model = QwenRegisteredDenseModel(rawValue: rawModel),
              let rawStage = values["--stage-index"], ["0", "1"].contains(rawStage), let stage = Int(rawStage),
              let rawTimeout = values["--timeout-seconds"], !rawTimeout.isEmpty,
              rawTimeout.utf8.allSatisfy({ (48...57).contains($0) }), let timeout = Int(rawTimeout),
              (1...300).contains(timeout), String(timeout) == rawTimeout else {
            throw ProbeError("Stage load mode, absolute directory, profile, selected stage or timeout differs")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        self.model = model; stageIndex = stage; timeoutSeconds = timeout
    }
}

struct QwenDenseStageLoadSelection {
    let metadata: QwenDenseConstructorAdmission
    let stageIndex: Int
    let forwardExecutionAuthorized = false, resourceAdmissionPerformed = false

    init(metadata: QwenDenseConstructorAdmission, stageIndex: Int) throws {
        guard [0, 1].contains(stageIndex), metadata.plan.stages.count == 2,
              metadata.plan.stages[0].sourceRange == 0..<(metadata.specification.layers / 2),
              metadata.plan.stages[1].sourceRange == (metadata.specification.layers / 2)..<metadata.specification.layers else {
            throw ProbeError("Stage load selects exactly one default registered half")
        }
        self.metadata = metadata; self.stageIndex = stageIndex
    }
}
