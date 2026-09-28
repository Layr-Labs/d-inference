import Darwin
import Foundation

extension QwenDenseShortParityCLI {
    func run() throws {
        alarm(UInt32(timeoutSeconds)); defer { alarm(0) }
        let start = DispatchTime.now().uptimeNanoseconds, limit = UInt64(timeoutSeconds) * 1_000_000_000
        func checked() throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start, now - start < limit else { throw ProbeError("Short parity exceeded its deadline") }
        }
        let metadata = try QwenDenseConstructorAdmission.admit(model: model,
            configuration: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifest: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment)
        let admission = try QwenDenseShortReferenceAdmission.admit(metadata: metadata, requestID: UUID(),
            promptData: QwenDenseShortParityInput.tokens(promptFile, expectedSHA256: promptSHA256), promptSHA256: promptSHA256,
            teacherData: QwenDenseShortParityInput.tokens(teacherFile, expectedSHA256: teacherSHA256), teacherSHA256: teacherSHA256)
        try checked()
        let output = QwenDenseShortParityOutput()
        let result = try runQwenDenseShortParity(directory: directory, admission: admission, onBaseline: { baseline in
            try output.publish(baseline, as: .baseline, check: checked, write: { try FileHandle.standardOutput.write(contentsOf: $0) })
        }, check: checked)
        try checked()
        try output.publish(result, as: .comparison, check: checked, write: { try FileHandle.standardOutput.write(contentsOf: $0) })
        try output.requireComplete(); try checked()
    }
}
