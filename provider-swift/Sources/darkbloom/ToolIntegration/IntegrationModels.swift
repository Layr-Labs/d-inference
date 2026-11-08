import Foundation
import ProviderCore

/// One model as a tool lists it: what Darkbloom's endpoint serves, with the catalog's name, limits and capabilities.
struct IntegrationModel: Equatable, Sendable {
    /// Where requests for the model run. The cases are declared in the order the tools list them, which is the order
    /// `Comparable` gives them.
    enum Location: Comparable, CaseIterable, Sendable {
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
    /// Set when the catalog didn't describe the model: offline, or a model it doesn't list. The name (unless an alias
    /// gave one), the capabilities and the limits the endpoint didn't give are then fallbacks, and a tool's own entry
    /// for the model keeps its values for them (`keeping(_:)`).
    var fallback: Fallback?

    struct Fallback: Equatable, Sendable {
        /// The endpoint's output cap; nil when it gave none.
        var endpointOutputCap: Int?
    }

    /// A model's entry in a tool's config, as the tool has it now; nil for what the entry doesn't hold.
    struct Entry: Equatable, Sendable {
        /// The name without where the model runs.
        var displayName: String?
        var contextLength: Int?
        var outputLimit: Int?
        var tools: Bool?
        var imageInput: Bool?
        var reasoning: Bool?
    }

    /// The model with what the tool's `entry` already says in place of its fallbacks, so a run without the catalog
    /// never downgrades what a run with it wrote: the name, tools, image input and reasoning, the context when the
    /// endpoint gives none, and the output while the context is the one it was set for (unless the endpoint gives a
    /// cap).
    func keeping(_ entry: Entry?) -> IntegrationModel {
        guard let fallback, let entry else { return self }
        let context = contextLength ?? entry.contextLength
        let keptOutput = fallback.endpointOutputCap == nil && context != nil && context == entry.contextLength
            ? entry.outputLimit : nil
        let cap = fallback.endpointOutputCap ?? IntegrationModels.defaultOutputCap
        let fallbackName = name == Self.name(id, at: location)
        return IntegrationModel(
            id: id, name: fallbackName ? entry.displayName.map { Self.name($0, at: location) } ?? name : name,
            location: location, contextLength: context,
            outputLimit: keptOutput ?? context.map { max(1, min(cap, $0 / 4)) },
            tools: entry.tools ?? tools, imageInput: entry.imageInput ?? imageInput,
            reasoning: entry.reasoning ?? reasoning, fallback: fallback)
    }

    /// `Qwen 3.8 27B (this Mac)`.
    static func name(_ display: String, at location: Location) -> String { "\(display) (\(location.label))" }

    /// A tool's name for a model without where it runs: `Qwen 3.8 27B (this Mac)` gives `Qwen 3.8 27B`.
    static func displayName(in name: String) -> String {
        for location in Location.allCases where name.hasSuffix(" (\(location.label))") {
            let display = name.dropLast(location.label.count + 3)
            if !display.isEmpty { return String(display) }
        }
        return name
    }
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
    /// the tool will see. `timeout` bounds the wait for an answer.
    static func fetch(
        _ endpoint: IntegrationEndpoint,
        timeout: TimeInterval = 5,
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
        request.timeoutInterval = timeout
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
    /// - A model the catalog doesn't describe carries `fallback`: a tool's own entry for it keeps its values
    ///   (`keeping(_:entries:)`).
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
                id: entry.id, name: IntegrationModel.name(display, at: location), location: location,
                contextLength: context, outputLimit: context.map { max(1, min(cap, $0 / 4)) },
                tools: capabilities.isEmpty || !capabilities.isDisjoint(with: toolCapabilities),
                imageInput: !capabilities.isDisjoint(with: imageCapabilities),
                reasoning: !capabilities.isDisjoint(with: reasoningCapabilities),
                fallback: details.model == nil ? .init(endpointOutputCap: positive(entry.maxOutputLength)) : nil)
        }
        return ordered(models)
    }

    /// The tools' order: this Mac, your Macs, the network, then by name.
    static func ordered(_ models: [IntegrationModel]) -> [IntegrationModel] {
        models.sorted { ($0.location, $0.name.lowercased(), $0.id) < ($1.location, $1.name.lowercased(), $1.id) }
    }

    /// `models` with a tool's `entries` (by model ID) kept for what the catalog didn't describe
    /// (`IntegrationModel.keeping`), in the tools' order again.
    static func keeping(_ models: [IntegrationModel], entries: [String: IntegrationModel.Entry]) -> [IntegrationModel] {
        let kept = models.map { $0.keeping(entries[$0.id]) }
        return kept == models ? models : ordered(kept)
    }

    /// Where a model the endpoint lists runs, from its `owned_by`.
    static func location(ownedBy: String?) -> IntegrationModel.Location {
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

    /// An endpoint ID's name in the catalog (an alias's, else its build's), else the ID: `Gemma 4 26B`.
    static func displayName(of id: String, in catalog: CatalogSnapshot?) -> String {
        catalogDetails(id, in: catalog).name.flatMap { $0.isEmpty ? nil : $0 } ?? id
    }
}
