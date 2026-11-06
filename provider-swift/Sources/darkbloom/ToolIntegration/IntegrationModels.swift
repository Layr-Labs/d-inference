import Foundation
import ProviderCore

/// One model as a tool lists it: what Darkbloom's endpoint serves, with the catalog's name, limits and capabilities.
struct IntegrationModel: Equatable, Sendable {
    /// Where requests for the model run, in the order the tools list them.
    enum Location: Int, Comparable, Sendable {
        case thisMac
        case yourMacs
        /// Other Darkbloom machines; listed only when the owner opted into "My Macs first".
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

    /// `GET <baseURL>/models`, with the key read from the endpoint's key file for this one request: exactly the list
    /// the tool will see.
    static func fetch(
        _ endpoint: IntegrationEndpoint,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [EndpointModel] {
        []
    }

    /// The tools' list: every chat model the endpoint lists, named and limited from the catalog when it is
    /// reachable (`catalog` nil offline), ordered this Mac, your Macs, the network, then by name.
    static func resolve(_ listed: [EndpointModel], catalog: CatalogSnapshot?) -> [IntegrationModel] {
        []
    }
}
