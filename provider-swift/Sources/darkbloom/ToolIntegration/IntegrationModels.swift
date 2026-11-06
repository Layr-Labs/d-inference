import Foundation
import ProviderCore

/// One model as a tool lists it: what Darkbloom's endpoint serves, with the catalog's name, limits and capabilities.
struct IntegrationModel: Equatable, Sendable {
    /// Where requests for the model run, in the order the tools list them.
    enum Location: Int, Comparable, Sendable {
        case thisMac
        case yourMacs
        /// Other Darkbloom machines: the local router lists them only when the owner opted into "My Macs first".
        case network

        var label: String {
            switch self {
            case .thisMac: "this Mac"
            case .yourMacs: "your Macs"
            case .network: "Darkbloom network, billed"
            }
        }

        static func < (lhs: Location, rhs: Location) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    /// The display name with where it runs: `Qwen 3.8 27B (this Mac)`.
    let name: String
    let location: Location
    /// Tokens the endpoint admits now; nil when neither the endpoint nor the catalog says.
    let contextLength: Int?
    /// The output cap the tools send as `max_tokens`; nil exactly when `contextLength` is.
    let outputLimit: Int?
    let tools: Bool
    let imageInput: Bool
    let reasoning: Bool
}

/// One entry of the endpoint's `GET /v1/models`.
struct EndpointModel: Decodable, Equatable, Sendable {
    let id: String
    /// `local` today; with the local router `this-mac`, `my-macs` or `darkbloom`.
    let ownedBy: String?
    let contextLength: Int?
    let maxOutputLength: Int?

    init(id: String, ownedBy: String? = nil, contextLength: Int? = nil, maxOutputLength: Int? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.contextLength = contextLength
        self.maxOutputLength = maxOutputLength
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case contextLength = "context_length"
        case maxModelLen = "max_model_len"
        case maxOutputLength = "max_output_length"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .maxModelLen)
        maxOutputLength = try container.decodeIfPresent(Int.self, forKey: .maxOutputLength)
    }
}

/// Why the endpoint's models could not be read. No case carries the key.
enum IntegrationModelsError: Error, Equatable, Sendable {
    case keyUnreadable(path: String)
    case badURL(String)
    case http(status: Int)
    case undecodable
}

/// Reads the endpoint's models and turns them into what the tools list.
enum IntegrationModels {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The output cap when neither the endpoint nor the catalog names one.
    static let defaultOutputCap = 32_768
    static let maximumResponseBytes = 4 << 20

    /// The catalog's capability names, as the coordinator's feature aliases spell them.
    static let toolCapabilities: Set<String> = ["tools", "tool_use", "tool_calling", "function_calling", "functions"]
    static let imageCapabilities: Set<String> = ["vision", "image", "image_input", "multimodal"]
    static let reasoningCapabilities: Set<String> = ["reasoning", "thinking", "reasoning_parser"]

    /// `GET <baseURL>/models`, with the key read from the endpoint's key file for this one request: exactly the list
    /// the tool will see.
    static func fetch(
        _ endpoint: IntegrationEndpoint,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [EndpointModel] {
        let key = (try? String(contentsOf: endpoint.keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw IntegrationModelsError.keyUnreadable(path: endpoint.keyFile.path) }
        let base = endpoint.baseURL.hasSuffix("/") ? String(endpoint.baseURL.dropLast()) : endpoint.baseURL
        guard let url = URL(string: base + "/models"), ["http", "https"].contains(url.scheme) else {
            throw IntegrationModelsError.badURL(endpoint.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw IntegrationModelsError.http(status: status) }
        guard data.count <= maximumResponseBytes,
              let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw IntegrationModelsError.undecodable
        }
        return list.data
    }

    private struct ModelList: Decodable {
        let data: [EndpointModel]
    }

    /// The tools' list: every chat model the endpoint lists, named and limited from the catalog when it is
    /// reachable (`catalog` nil offline), ordered this Mac, your Macs, the network, then by name.
    ///
    /// - Context: the endpoint's (what this engine admits now), else the catalog's maximum, else unknown.
    /// - Output cap: `min(max output, context / 4)`, the max output being the endpoint's, else the catalog's, else
    ///   `defaultOutputCap`.
    /// - Capabilities: the catalog's names; without them, tools on (Darkbloom serves tool calls on its chat models),
    ///   text input only (the engine refuses images on text-only builds) and no reasoning claim.
    static func resolve(_ listed: [EndpointModel], catalog: CatalogSnapshot?) -> [IntegrationModel] {
        var nearest: [String: (entry: EndpointModel, location: IntegrationModel.Location)] = [:]
        for entry in listed {
            let location = location(ownedBy: entry.ownedBy)
            if let kept = nearest[entry.id], kept.location <= location { continue }
            nearest[entry.id] = (entry, location)
        }
        let models = nearest.values.compactMap { listing -> IntegrationModel? in
            let (entry, location) = listing
            let details = catalogDetails(entry.id, in: catalog)
            if let kind = details.model?.modelType, kind != "text" { return nil }
            let context = positive(entry.contextLength) ?? positive(details.model?.maxContextLength)
            let cap = positive(entry.maxOutputLength) ?? positive(details.model?.maxOutputLength) ?? defaultOutputCap
            let capabilities = Set((details.model?.capabilities ?? []).map { $0.lowercased() })
            let display = details.name.flatMap { $0.isEmpty ? nil : $0 } ?? entry.id
            return IntegrationModel(
                id: entry.id, name: "\(display) (\(location.label))", location: location, contextLength: context,
                outputLimit: context.map { max(1, min(cap, $0 / 4)) },
                tools: capabilities.isEmpty || !capabilities.isDisjoint(with: toolCapabilities),
                imageInput: !capabilities.isDisjoint(with: imageCapabilities),
                reasoning: !capabilities.isDisjoint(with: reasoningCapabilities))
        }
        return models.sorted { ($0.location, $0.name.lowercased(), $0.id) < ($1.location, $1.name.lowercased(), $1.id) }
    }

    private static func location(ownedBy: String?) -> IntegrationModel.Location {
        switch ownedBy?.lowercased() {
        case "my-macs": .yourMacs
        case "darkbloom": .network
        default: .thisMac
        }
    }

    /// The catalog's name and build for an endpoint ID: an alias ID names the alias and its desired build; a build
    /// an alias points to takes the alias's name.
    private static func catalogDetails(_ id: String, in catalog: CatalogSnapshot?) -> (name: String?, model: CatalogModel?) {
        guard let catalog else { return (nil, nil) }
        if let alias = catalog.aliases.first(where: { $0.id == id }) {
            let build = catalog.models.first { $0.id == alias.desiredBuild }
                ?? alias.primaryBuild.flatMap { primary in catalog.models.first { $0.id == primary } }
            return (alias.displayName, build)
        }
        guard let model = catalog.models.first(where: { $0.id == id }) else { return (nil, nil) }
        let alias = catalog.aliases.first { $0.desiredBuild == id }
        return (alias?.displayName ?? model.displayName, model)
    }

    private static func positive(_ value: Int?) -> Int? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }
}
