import Foundation

struct LMStudioLoadedModel: Sendable, Equatable {
    let darkbloomID: String
    let instanceID: String
    let sizeBytes: UInt64
    let quantization: String
    let contextLength: Int64
    let maxConcurrency: UInt32
    let isVision: Bool

    var modelInfo: ModelInfo {
        ModelInfo(
            id: darkbloomID,
            modelType: "chat",
            quantization: quantization,
            sizeBytes: sizeBytes,
            estimatedMemoryGb: Double(sizeBytes) / 1_073_741_824,
            isVision: isVision
        )
    }
}

enum LMStudioClientError: Error {
    case invalidResponse
    case httpStatus(Int)
    case invalidRequest

    var statusCode: UInt16 {
        switch self {
        case .httpStatus(let status) where (400..<500).contains(status):
            return UInt16(status)
        default:
            return 502
        }
    }
}

struct LMStudioClient: Sendable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:1234")!

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func loadedModels() async throws -> [LMStudioLoadedModel] {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/models"))
        request.timeoutInterval = 1
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LMStudioClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw LMStudioClientError.httpStatus(http.statusCode)
        }

        let payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return payload.models.compactMap { model in
            guard model.type == "llm", !model.key.isEmpty,
                let instance = model.loadedInstances.first, !instance.id.isEmpty
            else { return nil }
            return LMStudioLoadedModel(
                darkbloomID: "lmstudio/\(model.key)",
                instanceID: instance.id,
                sizeBytes: model.sizeBytes,
                quantization: model.quantization?.name ?? "",
                contextLength: instance.config?.contextLength ?? model.maxContextLength ?? 0,
                maxConcurrency: UInt32(clamping: max(1, instance.config?.parallel ?? 1)),
                isVision: model.capabilities?.vision ?? false
            )
        }.sorted { $0.darkbloomID < $1.darkbloomID }
    }

    func streamChatCompletion(
        body: Data,
        instanceID: String,
        onEvent: (String) async throws -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.streamingRequestBody(body, instanceID: instanceID)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LMStudioClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LMStudioClientError.httpStatus(http.statusCode)
        }

        var eventBytes = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            eventBytes.append(byte)
            if eventBytes.count > 1_048_576 {
                throw LMStudioClientError.invalidResponse
            }
            let separatorLength: Int
            if eventBytes.suffix(2).elementsEqual([10, 10]) {
                separatorLength = 2
            } else if eventBytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                separatorLength = 4
            } else {
                continue
            }
            let payload = eventBytes.dropLast(separatorLength)
            if !payload.isEmpty {
                let event = String(decoding: payload, as: UTF8.self)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                try await onEvent(event + "\n\n")
            }
            eventBytes.removeAll(keepingCapacity: true)
        }
        if !eventBytes.isEmpty {
            let event = String(decoding: eventBytes, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
            try await onEvent(event + "\n\n")
        }
    }

    static func streamingRequestBody(_ body: Data, instanceID: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LMStudioClientError.invalidRequest
        }
        object["model"] = instanceID
        object["stream"] = true
        var streamOptions = object["stream_options"] as? [String: Any] ?? [:]
        streamOptions["include_usage"] = true
        object["stream_options"] = streamOptions
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension LMStudioClient {
    struct ModelsResponse: Decodable {
        let models: [Model]
    }

    struct Model: Decodable {
        let type: String
        let key: String
        let sizeBytes: UInt64
        let maxContextLength: Int64?
        let quantization: Quantization?
        let loadedInstances: [LoadedInstance]
        let capabilities: Capabilities?

        enum CodingKeys: String, CodingKey {
            case type, key, quantization, capabilities
            case sizeBytes = "size_bytes"
            case maxContextLength = "max_context_length"
            case loadedInstances = "loaded_instances"
        }
    }

    struct Quantization: Decodable {
        let name: String
    }

    struct Capabilities: Decodable {
        let vision: Bool?
    }

    struct LoadedInstance: Decodable {
        let id: String
        let config: InstanceConfig?
    }

    struct InstanceConfig: Decodable {
        let contextLength: Int64?
        let parallel: Int?

        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case parallel
        }
    }
}
