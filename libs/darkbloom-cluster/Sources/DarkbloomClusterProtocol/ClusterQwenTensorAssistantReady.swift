/// Actual resident assistant observation. The native owner publishes this
/// only after its verified head, target and bilateral LOAD agreement succeed.
/// Capacity is the owner's admitted lane count, not a speculative width or a
/// promise that every request uses the assistant.
public struct ClusterQwenTensorAssistantReady: Equatable, Sendable {
    public let policy: ClusterQwenTensorAssistantPolicy
    public let capacity: Int
    public let maximumSpeculativeWidth: Int

    public init(policy: ClusterQwenTensorAssistantPolicy, capacity: Int, maximumSpeculativeWidth: Int? = nil) throws {
        self.policy = policy; self.capacity = capacity
        self.maximumSpeculativeWidth = try maximumSpeculativeWidth ?? policy.maximumSpeculativeWidth(capacity: capacity)
        try validate()
    }
    public func validate() throws {
        try policy.validate()
        try workerRequire((1...8).contains(capacity), "Invalid tensor assistant resident capacity")
        let expected = try policy.maximumSpeculativeWidth(capacity: capacity)
        try workerRequire(maximumSpeculativeWidth == expected,
            "Resident tensor assistant verification width differs from its policy")
    }

    public static func require(_ actual: Self?, policy: ClusterQwenTensorAssistantPolicy?, capacity: Int) throws {
        if let policy {
            try policy.validate()
            try actual?.validate()
            try workerRequire(actual?.policy == policy && actual?.capacity == capacity,
                "Resident tensor assistant differs from the saved policy or capacity")
        } else {
            try workerRequire(actual == nil, "Unexpected resident tensor assistant without a saved policy")
        }
    }

    var object: [String: Any] {
        var result: [String: Any] = ["policy": policy.object, "capacity": capacity]
        if policy.verification != .singleton { result["maximumSpeculativeWidth"] = maximumSpeculativeWidth }
        return result
    }
    static func decodeObject(_ object: [String: Any]) throws -> Self {
        var reader = WorkerObject(object)
        let policy = try ClusterQwenTensorAssistantPolicy.decodeObject(reader.object("policy"))
        let capacity = try reader.int("capacity")
        let width = try reader.optionalInt("maximumSpeculativeWidth")
        try workerRequire(policy.verification != .admittedCohort || width != nil,
            "Cohort assistant readiness must report its observed verification width")
        try reader.finish()
        return try .init(policy: policy, capacity: capacity, maximumSpeculativeWidth: width ?? 1)
    }
}
