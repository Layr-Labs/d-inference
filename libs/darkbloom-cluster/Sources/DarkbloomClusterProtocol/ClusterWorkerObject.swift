import Foundation
import CoreFoundation

struct WorkerObject {
    var values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    mutating func take(_ key: String) throws -> Any {
        guard let value = values.removeValue(forKey: key) else { throw ClusterWorkerProtocolError.invalid("Missing field: " + key) }
        return value
    }
    mutating func string(_ key: String) throws -> String {
        guard let value = try take(key) as? String else { throw ClusterWorkerProtocolError.invalid("Expected string: " + key) }
        return value
    }
    mutating func bool(_ key: String) throws -> Bool {
        guard let value = try take(key) as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw ClusterWorkerProtocolError.invalid("Expected Boolean: " + key)
        }
        return value.boolValue
    }
    mutating func number(_ key: String) throws -> NSNumber {
        guard let value = try take(key) as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw ClusterWorkerProtocolError.invalid("Expected integer: " + key)
        }
        return value
    }
    mutating func int(_ key: String) throws -> Int {
        guard let value = Int(try number(key).stringValue) else { throw ClusterWorkerProtocolError.invalid("Integer overflow: " + key) }
        return value
    }
    mutating func uint(_ key: String) throws -> UInt64 {
        guard let value = UInt64(try number(key).stringValue) else { throw ClusterWorkerProtocolError.invalid("Unsigned overflow: " + key) }
        return value
    }
    mutating func uuid(_ key: String) throws -> UUID {
        let text = try string(key)
        guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
            throw ClusterWorkerProtocolError.invalid("Expected canonical lowercase UUID: " + key)
        }
        return value
    }
    mutating func optionalUUID(_ key: String) throws -> UUID? { values[key] == nil ? nil : try uuid(key) }
    mutating func optionalInt(_ key: String) throws -> Int? { values[key] == nil ? nil : try int(key) }
    mutating func enumeration<T: RawRepresentable>(_ key: String) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: try string(key)) else { throw ClusterWorkerProtocolError.invalid("Unknown enum: " + key) }
        return value
    }
    mutating func object(_ key: String) throws -> [String: Any] {
        guard let value = try take(key) as? [String: Any] else { throw ClusterWorkerProtocolError.invalid("Expected object: " + key) }
        return value
    }
    mutating func optionalObject(_ key: String) throws -> [String: Any]? { values[key] == nil ? nil : try object(key) }
    mutating func objects(_ key: String) throws -> [[String: Any]] {
        guard let value = try take(key) as? [[String: Any]] else { throw ClusterWorkerProtocolError.invalid("Expected object array: " + key) }
        return value
    }
    mutating func ints(_ key: String) throws -> [Int] {
        guard let value = try take(key) as? [Any] else { throw ClusterWorkerProtocolError.invalid("Expected integer array: " + key) }
        // A prompt's tokens arrive here (31.5K of them, ~54 ms through `int`).
        // An integer-typed, non-Boolean CFNumber holds exactly its Int64 value,
        // which `int`'s decimal round trip returns; anything else takes `int`.
        var result = [Int]()
        result.reserveCapacity(value.count)
        for item in value {
            if let number = item as? NSNumber, !(number is NSDecimalNumber),
               CFGetTypeID(number) == CFNumberGetTypeID(), !CFNumberIsFloatType(number) {
                result.append(Int(number.int64Value))
            } else {
                var r = WorkerObject([key: item]); result.append(try r.int(key))
            }
        }
        return result
    }
    func peekString(_ key: String) -> String? { values[key] as? String }
    func finish() throws { try workerRequire(values.isEmpty, "Unknown worker record fields") }
}
