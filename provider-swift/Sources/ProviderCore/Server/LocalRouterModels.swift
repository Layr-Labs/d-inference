import Foundation
import NIOCore
import NIOFoundationCompat

/// Context and output limits of one model, in tokens. nil: not known here.
public struct LocalModelLimits: Sendable, Equatable {
    public var contextLength: Int?
    public var maxOutputLength: Int?

    public init(contextLength: Int? = nil, maxOutputLength: Int? = nil) {
        self.contextLength = contextLength.flatMap { $0 > 0 ? $0 : nil }
        self.maxOutputLength = maxOutputLength.flatMap { $0 > 0 ? $0 : nil }
    }

    /// A single Mac slot's limits: its window holds a request's prompt and output
    /// together, so either may be at most the window and both are listed as it.
    /// (A `max_tokens` past what the prompt leaves is cut to fit, or refused
    /// past an advertised context.)
    public init(window: Int?) {
        self.init(contextLength: window, maxOutputLength: window)
    }
}

/// One entry of the router's `/v1/models`: the integration contract for OpenCode and Hermes.
///
/// `owned_by` says where the model runs: `this-mac`, `my-macs` (the owner's other Macs, free) or `darkbloom` (the
/// network, billed; listed only with `my-macs-first`). `context_length` and `max_output_length` are present when
/// known: this Mac's engine first, else the Darkbloom catalog (the coordinator's own `self` list has no limits).
struct LocalRouterModelEntry: Codable, Equatable, Sendable {
    var id: String
    var object = "model"
    var created: Int?
    var ownedBy: String
    var name: String?
    var contextLength: Int?
    var maxOutputLength: Int?

    enum CodingKeys: String, CodingKey {
        case id, object, created, name
        case ownedBy = "owned_by"
        case contextLength = "context_length"
        case maxModelLen = "max_model_len"
        case maxOutputLength = "max_output_length"
    }

    init(id: String, created: Int?, ownedBy: String, name: String? = nil, limits: LocalModelLimits = .init()) {
        self.id = id
        self.created = created
        self.ownedBy = ownedBy
        self.name = name
        contextLength = limits.contextLength
        maxOutputLength = limits.maxOutputLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        created = try? container.decodeIfPresent(Int.self, forKey: .created)
        ownedBy = (try? container.decodeIfPresent(String.self, forKey: .ownedBy)) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        let context = (try? container.decodeIfPresent(Int.self, forKey: .contextLength))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .maxModelLen))
        contextLength = context.flatMap { $0 > 0 ? $0 : nil }
        maxOutputLength = (try? container.decodeIfPresent(Int.self, forKey: .maxOutputLength)).flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(object, forKey: .object)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encode(ownedBy, forKey: .ownedBy)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(contextLength, forKey: .contextLength)
        // vLLM's name for the same number, as the engine's own list writes it.
        try container.encodeIfPresent(contextLength, forKey: .maxModelLen)
        try container.encodeIfPresent(maxOutputLength, forKey: .maxOutputLength)
    }

    mutating func fill(_ limits: LocalModelLimits?) {
        guard let limits else { return }
        if contextLength == nil { contextLength = limits.contextLength }
        if maxOutputLength == nil { maxOutputLength = limits.maxOutputLength }
    }
}

struct LocalRouterModelList: Codable {
    var object = "list"
    var data: [LocalRouterModelEntry]

    init(data: [LocalRouterModelEntry]) { self.data = data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([LocalRouterModelEntry].self, forKey: .data)
    }
}

/// The owner's Macs as the coordinator's `self` view reports one model: how many of them serve it now. A Mac paused
/// for its owner still counts.
struct LocalRouterOwnedModel: Decodable {
    struct Metadata: Decodable {
        var providerCount: Int?
        enum CodingKeys: String, CodingKey { case providerCount = "provider_count" }
    }
    var metadata: Metadata?
    var providerCount: Int { metadata?.providerCount ?? 0 }
}

/// The parts of the Darkbloom catalog (`GET /v1/models/catalog?include_aliases=1`, keyless) the router reads: each
/// build's limits, and the builds behind each public alias.
struct LocalRouterCatalog: Sendable, Equatable {
    var limits: [String: LocalModelLimits] = [:]
    var displayNames: [String: String] = [:]
    /// Alias id → the builds that serve it (desired, previous, primary).
    var aliasBuilds: [String: [String]] = [:]

    func limits(of id: String) -> LocalModelLimits? {
        if let own = limits[id] { return own }
        return aliasBuilds[id]?.lazy.compactMap { limits[$0] }.first
    }

    /// `id`, or every build of the alias `id`.
    func builds(of id: String) -> [String] { [id] + (aliasBuilds[id] ?? []) }

    static func decode(_ data: Data) -> LocalRouterCatalog? {
        struct Wire: Decodable {
            struct Model: Decodable {
                var id: String
                var displayName: String?
                var maxContextLength: Int?
                var maxOutputLength: Int?
                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                    case maxContextLength = "max_context_length"
                    case maxOutputLength = "max_output_length"
                }
            }
            struct Alias: Decodable {
                var id: String
                var displayName: String?
                var desiredBuild: String?
                var previousBuild: String?
                var primaryBuild: String?
                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                    case desiredBuild = "desired_build"
                    case previousBuild = "previous_build"
                    case primaryBuild = "primary_build"
                }
            }
            var models: [Model]
            var aliases: [Alias]?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        var catalog = LocalRouterCatalog()
        for model in wire.models {
            catalog.limits[model.id] = LocalModelLimits(contextLength: model.maxContextLength,
                                                        maxOutputLength: model.maxOutputLength)
            if let name = model.displayName, !name.isEmpty { catalog.displayNames[model.id] = name }
        }
        for alias in wire.aliases ?? [] {
            var builds: [String] = []
            for build in [alias.desiredBuild, alias.primaryBuild, alias.previousBuild] {
                if let build, !build.isEmpty, !builds.contains(build) { builds.append(build) }
            }
            catalog.aliasBuilds[alias.id] = builds
            if let name = alias.displayName, !name.isEmpty { catalog.displayNames[alias.id] = name }
        }
        return catalog
    }
}

enum LocalRouterModelMerge {
    /// This Mac's models first (labelled `this-mac`), then the upstream lists in order, each model once: by id, and
    /// an upstream public alias of a build this Mac lists counts as that build. (On a Mac that also serves Darkbloom,
    /// the coordinator's `self` list names this Mac's own builds by their aliases.)
    static func merge(local: [LocalRouterModelEntry], upstream: [(ownedBy: String, entries: [LocalRouterModelEntry])],
                      localLimits: [String: LocalModelLimits], catalog: LocalRouterCatalog?) -> [LocalRouterModelEntry] {
        var seen = Set<String>()
        let localIDs = Set(local.map(\.id))
        var merged: [LocalRouterModelEntry] = []
        for var entry in local where seen.insert(entry.id).inserted {
            entry.ownedBy = LocalRouterPolicy.thisMac
            entry.fill(localLimits[entry.id])
            entry.fill(catalog?.limits(of: entry.id))
            merged.append(entry)
        }
        for list in upstream {
            for var entry in list.entries where seen.insert(entry.id).inserted {
                if let builds = catalog?.aliasBuilds[entry.id], !localIDs.isDisjoint(with: builds) { continue }
                entry.ownedBy = list.ownedBy
                entry.fill(catalog?.limits(of: entry.id))
                if entry.name == nil || entry.name == entry.id { entry.name = catalog?.displayNames[entry.id] ?? entry.name }
                merged.append(entry)
            }
        }
        return merged
    }
}
