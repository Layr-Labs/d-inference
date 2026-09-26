import Foundation

extension ProviderMessage {
    public struct ModelsReplace: Codable, Sendable, Equatable {
        public var requestId: String
        public var drainRequestId: String
        public var validateOnly: Bool
        public var models: [ModelInfo]
        public var toolConstraintProtocol: Int?
        public var toolConstraintModels: [String]?

        public init(requestId: String, drainRequestId: String, models: [ModelInfo],
                    validateOnly: Bool = false, toolConstraintProtocol: Int? = nil,
                    toolConstraintModels: [String]? = nil) {
            self.requestId = requestId
            self.drainRequestId = drainRequestId
            self.validateOnly = validateOnly
            self.models = models
            self.toolConstraintProtocol = toolConstraintProtocol
            self.toolConstraintModels = toolConstraintModels
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestId = try container.decode(String.self, forKey: .requestId)
            drainRequestId = try container.decode(String.self, forKey: .drainRequestId)
            validateOnly = try container.decodeIfPresent(Bool.self, forKey: .validateOnly) ?? false
            models = try container.decode([ModelInfo].self, forKey: .models)
            toolConstraintProtocol = try container.decodeIfPresent(Int.self, forKey: .toolConstraintProtocol)
            toolConstraintModels = try container.decodeIfPresent([String].self, forKey: .toolConstraintModels)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(drainRequestId, forKey: .drainRequestId)
            if validateOnly { try container.encode(true, forKey: .validateOnly) }
            try container.encode(models, forKey: .models)
            try container.encodeIfPresent(toolConstraintProtocol, forKey: .toolConstraintProtocol)
            try container.encodeIfPresent(toolConstraintModels, forKey: .toolConstraintModels)
        }

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case drainRequestId = "drain_request_id"
            case validateOnly = "validate_only"
            case models
            case toolConstraintProtocol = "tool_constraint_protocol"
            case toolConstraintModels = "tool_constraint_models"
        }
    }
}

extension CoordinatorMessage {
    public struct ModelsReplaceAck: Codable, Sendable, Equatable {
        public var requestId: String
        public var drainRequestId: String
        public var validateOnly: Bool
        public var accepted: Bool
        public var error: String?

        public init(requestId: String, drainRequestId: String, validateOnly: Bool = false,
                    accepted: Bool, error: String? = nil) {
            self.requestId = requestId
            self.drainRequestId = drainRequestId
            self.validateOnly = validateOnly
            self.accepted = accepted
            self.error = error
        }

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case drainRequestId = "drain_request_id"
            case validateOnly = "validate_only"
            case accepted, error
        }
    }
}
