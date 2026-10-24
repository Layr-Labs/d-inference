import Foundation

/// A requested resident assistant on the existing Qwen27 tensor owner.
/// The exact artifact/configuration/build pins remain authoritative. This
/// value grants neither memory nor readiness and selects no generation mode.
public struct ClusterQwenTensorAssistantPolicy: Codable, Equatable, Sendable {
    public enum Verification: String, Codable, Sendable {
        case singleton = "singleton_ready_set_v1"
        case admittedCohort = "admitted_target_cohort_v1"
    }
    public static let schemaName = "qwen27_tensor_assistant_v1"
    public static let inventoryArgument = "--tp-mtp-inventory-sha256"
    public static let verificationArgument = "--tp-mtp-verification"
    public static let runtimeModelID = "registered_qwen38_27b"
    public let schema: String
    public let depth: Int
    public let inventorySHA256: String
    public let verification: Verification

    public init(depth: Int, inventorySHA256: String, verification: Verification = .singleton) throws {
        schema = Self.schemaName; self.depth = depth; self.inventorySHA256 = inventorySHA256
        self.verification = verification
        try validate()
    }

    public func maximumSpeculativeWidth(capacity: Int) throws -> Int {
        try validate()
        try workerRequire((1...8).contains(capacity), "Invalid tensor assistant verification capacity")
        return verification == .admittedCohort ? capacity : 1
    }

    /// Omission preserves the legacy launch and quote byte contract. A cohort
    /// is explicit and must be accepted by both installed worker binaries.
    public var verificationArguments: [String] {
        verification == .singleton ? [] : [Self.verificationArgument, verification.rawValue]
    }

    public func validate() throws {
        try workerRequire(schema == Self.schemaName && (1...4).contains(depth)
            && ClusterWorkerValidation.hash(inventorySHA256), "Invalid Qwen27 tensor assistant policy")
    }

    /// The owner/wire strict readers already reject duplicate keys and
    /// non-integer number syntax before Foundation sees the object.
    public static func decodeObject(_ object: [String: Any]) throws -> Self {
        var reader = WorkerObject(object)
        let schema = try reader.string("schema"), depth = try reader.int("depth")
        let inventory = try reader.string("inventorySHA256")
        let verification: Verification
        if reader.values["verification"] == nil { verification = .singleton }
        else { verification = try reader.enumeration("verification") }
        try reader.finish()
        try workerRequire(schema == schemaName, "Unknown Qwen27 tensor assistant policy")
        return try .init(depth: depth, inventorySHA256: inventory, verification: verification)
    }

    public var object: [String: Any] {
        var result: [String: Any] = ["schema": schema, "depth": depth, "inventorySHA256": inventorySHA256]
        if verification != .singleton { result["verification"] = verification.rawValue }
        return result
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Field.self)
        let keys = Set(values.allKeys.map(\.stringValue)), required: Set<String> = ["schema", "depth", "inventorySHA256"]
        try workerRequire(required.isSubset(of: keys) && keys.isSubset(of: required.union(["verification"])),
            "Unknown or missing tensor assistant policy fields")
        schema = try values.decode(String.self, forKey: Field(stringValue: "schema"))
        depth = try values.decode(Int.self, forKey: Field(stringValue: "depth"))
        inventorySHA256 = try values.decode(String.self, forKey: Field(stringValue: "inventorySHA256"))
        verification = values.contains(Field(stringValue: "verification"))
            ? try values.decode(Verification.self, forKey: Field(stringValue: "verification")) : .singleton
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: Field.self)
        try values.encode(schema, forKey: Field(stringValue: "schema"))
        try values.encode(depth, forKey: Field(stringValue: "depth"))
        try values.encode(inventorySHA256, forKey: Field(stringValue: "inventorySHA256"))
        if verification != .singleton { try values.encode(verification, forKey: Field(stringValue: "verification")) }
    }
}
