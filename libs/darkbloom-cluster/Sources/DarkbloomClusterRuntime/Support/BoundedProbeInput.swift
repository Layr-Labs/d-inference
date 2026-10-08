import CoreFoundation
import Foundation

/// Shared byte and integer parsing for explicitly bounded diagnostics.
enum BoundedProbeInput {
    static func data(_ file: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ProbeError("Diagnostic input file is empty or exceeds its byte limit")
        }
        return data
    }

    static func tokenIDs(_ file: URL) throws -> [Int] {
        let bytes = try data(file, maximumBytes: 65_536)
        try validateWorkerJSON(bytes)
        return try JSONDecoder().decode([Int].self, from: bytes)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }
}
