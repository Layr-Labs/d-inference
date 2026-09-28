import Foundation
import Darwin

extension QwenDenseConstructorCLI {
    func run() throws {
        alarm(UInt32(timeoutSeconds)); defer { alarm(0) }
        let start = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(timeoutSeconds) * 1_000_000_000
        func checked() throws {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start, now - start < limit else { throw ProbeError("Constructor probe exceeded its deadline") }
        }
        func bounded(_ name: String, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard !data.isEmpty, data.count <= limit else { throw ProbeError("Constructor probe metadata exceeds its byte bound") }
            return data
        }
        let admission = try QwenDenseConstructorAdmission.admit(model: model,
            configuration: bounded("config.json", limit: 1_048_576),
            manifest: bounded("manifest.json", limit: 4_194_304),
            environment: ProcessInfo.processInfo.environment)
        try checked()
        let result = try runQwenDenseConstructorProbe(directory: directory, admission: admission, check: checked)
        try checked()
        try emitJSON(result)
    }
}
