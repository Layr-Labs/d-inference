import Darwin
import Foundation

extension QwenDenseStageLoadCLI {
    func run() throws {
        alarm(UInt32(timeoutSeconds)); defer { alarm(0) }
        let start = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(timeoutSeconds) * 1_000_000_000
        func checked() throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start, now - start < limit else { throw ProbeError("Selected-stage load exceeded its deadline") }
        }
        let metadata = try QwenDenseConstructorAdmission.admit(model: model,
            configuration: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifest: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment)
        let selection = try QwenDenseStageLoadSelection(metadata: metadata, stageIndex: stageIndex)
        try checked()
        let result = try runQwenDenseStageLoadProbe(directory: directory, selection: selection, check: checked)
        try checked()
        var data = try canonicalJSONData(result)
        guard data.count < 8 * 1_048_576 else { throw ProbeError("Selected-stage load report exceeds 8 MiB") }
        data.append(10)
        try checked()
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
