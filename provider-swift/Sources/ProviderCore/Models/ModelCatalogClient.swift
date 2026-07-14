/// ModelCatalogClient -- coordinator-side catalog HTTP client.
///
/// Fetches the canonical catalog + per-model manifests from the
/// coordinator (`GET /v1/models/catalog`, `/v1/models/{id}/manifest`).
/// Split out of ModelCatalog.swift; see also ModelDownloader.swift.

import Foundation

// MARK: - Catalog client

public struct ModelCatalogClient: Sendable {

    static let maximumCatalogResponseBytes = 4 * 1024 * 1024
    static let maximumManifestResponseBytes = 1 * 1024 * 1024
    static let maximumCatalogModelCount = 4_096
    static let maximumCatalogAliasCount = 4_096
    private static let maximumManifestFileCount = 16_384
    private static let maximumJSONNestingDepth = 32
    private static let maximumJSONStringBytes = 256 * 1024
    private static let maximumJSONCollectionCount = 4_096

    private let coordinatorURL: String
    private let urlSession: URLSession

    public init(coordinatorURL: String, urlSession: URLSession = .shared) {
        self.coordinatorURL = coordinatorHTTPBase(coordinatorURL)
        self.urlSession = urlSession
    }

    /// Fetch the active catalog from the coordinator. `typeFilter` mirrors
    /// the coordinator's `?type=` query parameter (e.g. "text").
    public func fetchCatalog(typeFilter: String? = nil) async throws -> [CatalogModel] {
        try await fetchCatalogSnapshot(typeFilter: typeFilter, includeAliases: false).models
    }

    public func fetchCatalogSnapshot(typeFilter: String? = nil, includeAliases: Bool = false) async throws -> CatalogSnapshot {
        var components = URLComponents(string: "\(coordinatorURL)/v1/models/catalog")!
        var queryItems: [URLQueryItem] = []
        if let typeFilter, !typeFilter.isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: typeFilter))
        }
        if includeAliases {
            queryItems.append(URLQueryItem(name: "include_aliases", value: "1"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw ModelCatalogError.unreachable("invalid catalog URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(
                for: request,
                maximumBytes: Self.maximumCatalogResponseBytes,
                responseName: "catalog response")
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            try Self.validateJSONLexicalBounds(data, responseName: "catalog response")
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
            try Self.validateCatalogBounds(decoded)
            return CatalogSnapshot(models: decoded.models, aliases: decoded.aliases ?? [])
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.decodeFailed(error.localizedDescription)
        }
    }

    /// Fetch the active registry manifest for a model. Model IDs can contain
    /// `/`, so the ID is percent-encoded as one path suffix.
    public func fetchManifest(modelID: String) async throws -> ModelManifest {
        guard let escapedID = Self.escapeModelIDForPath(modelID),
              let url = URL(string: "\(coordinatorURL)/v1/models/catalog/manifest/\(escapedID)")
        else {
            throw ModelCatalogError.unreachable("invalid manifest URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(
                for: request,
                maximumBytes: Self.maximumManifestResponseBytes,
                responseName: "manifest response")
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            try Self.validateJSONLexicalBounds(data, responseName: "manifest response")
            let manifest = try Self.manifestDecoder.decode(ModelManifest.self, from: data)
            try Self.validateManifestBounds(manifest)
            return manifest
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.decodeFailed(error.localizedDescription)
        }
    }

    static let manifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func escapeModelIDForPath(_ modelID: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return modelID.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// `URLSession.data(for:)` buffers without an application byte ceiling.
    /// Consume the response stream directly so a missing or dishonest
    /// Content-Length cannot make catalog JSON an unbounded allocation.
    private func boundedData(
        for request: URLRequest,
        maximumBytes: Int,
        responseName: String
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await urlSession.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ModelCatalogError.decodeFailed("\(responseName) exceeds \(maximumBytes)-byte bound")
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw ModelCatalogError.decodeFailed(
                        "\(responseName) exceeds \(maximumBytes)-byte bound")
                }
                data.append(byte)
            }
        } catch let error as ModelCatalogError {
            throw error
        }
        return (data, response)
    }

    /// Cheap lexical limits run before recursive Codable decoding. They are
    /// deliberately not a JSON parser; malformed syntax still belongs to
    /// JSONDecoder, while depth and individual string size are bounded here.
    private static func validateJSONLexicalBounds(
        _ data: Data,
        responseName: String
    ) throws {
        var depth = 0
        var inString = false
        var escaped = false
        var stringBytes = 0

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    stringBytes = 0
                } else {
                    stringBytes += 1
                    if stringBytes > maximumJSONStringBytes {
                        throw ModelCatalogError.decodeFailed(
                            "\(responseName) contains an oversized JSON string")
                    }
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
                stringBytes = 0
            case 0x7b, 0x5b:
                depth += 1
                if depth > maximumJSONNestingDepth {
                    throw ModelCatalogError.decodeFailed(
                        "\(responseName) exceeds JSON nesting bound")
                }
            case 0x7d, 0x5d:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
    }

    private static func validateCatalogBounds(_ response: CatalogResponse) throws {
        guard response.models.count <= maximumCatalogModelCount else {
            throw ModelCatalogError.decodeFailed("catalog model count exceeds provider bound")
        }
        let aliases = response.aliases ?? []
        guard aliases.count <= maximumCatalogAliasCount else {
            throw ModelCatalogError.decodeFailed("catalog alias count exceeds provider bound")
        }
        guard response.models.allSatisfy(modelWithinBounds),
            aliases.allSatisfy(aliasWithinBounds)
        else {
            throw ModelCatalogError.decodeFailed("catalog field exceeds provider structural bound")
        }
    }

    private static func modelWithinBounds(_ model: CatalogModel) -> Bool {
        let strings = [
            model.id, model.s3Name, model.displayName, model.modelType,
            model.architecture, model.description, model.weightHash, model.version,
            model.r2Prefix, model.aggregateSHA256, model.family, model.quantization,
        ].compactMap { $0 }
        guard strings.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }),
            (model.capabilities?.count ?? 0) <= maximumJSONCollectionCount,
            model.capabilities?.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }) ?? true,
            jsonDictionaryWithinBounds(model.runtimeParameters),
            jsonDictionaryWithinBounds(model.metadata)
        else { return false }
        return true
    }

    private static func aliasWithinBounds(_ alias: CatalogAlias) -> Bool {
        let strings = [
            alias.id, alias.displayName, alias.desiredBuild,
            alias.previousBuild, alias.primaryBuild,
        ].compactMap { $0 }
        return strings.allSatisfy { $0.utf8.count <= maximumJSONStringBytes }
            && (alias.retiredBuilds?.count ?? 0) <= maximumJSONCollectionCount
            && (alias.retiredBuilds?.allSatisfy {
                $0.utf8.count <= maximumJSONStringBytes
            } ?? true)
    }

    private static func jsonDictionaryWithinBounds(
        _ dictionary: [String: JSONValue]?
    ) -> Bool {
        guard let dictionary else { return true }
        guard dictionary.count <= maximumJSONCollectionCount else { return false }
        return dictionary.allSatisfy {
            $0.key.utf8.count <= maximumJSONStringBytes
                && jsonValueWithinBounds($0.value, depth: 1)
        }
    }

    private static func jsonValueWithinBounds(_ value: JSONValue, depth: Int) -> Bool {
        guard depth <= maximumJSONNestingDepth else { return false }
        switch value {
        case .null, .bool, .int, .double:
            return true
        case .string(let string):
            return string.utf8.count <= maximumJSONStringBytes
        case .array(let values):
            return values.count <= maximumJSONCollectionCount
                && values.allSatisfy { jsonValueWithinBounds($0, depth: depth + 1) }
        case .object(let pairs):
            return pairs.count <= maximumJSONCollectionCount
                && pairs.allSatisfy {
                    $0.0.utf8.count <= maximumJSONStringBytes
                        && jsonValueWithinBounds($0.1, depth: depth + 1)
                }
        }
    }

    private static func validateManifestBounds(_ manifest: ModelManifest) throws {
        let strings = [
            manifest.modelID, manifest.version, manifest.r2Prefix,
            manifest.aggregateSHA256,
        ]
        guard manifest.files.count <= maximumManifestFileCount,
            strings.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }),
            manifest.files.allSatisfy({ file in
                file.path.utf8.count <= maximumJSONStringBytes
                    && file.sha256.utf8.count <= maximumJSONStringBytes
                    && file.role.utf8.count <= maximumJSONStringBytes
            })
        else {
            throw ModelCatalogError.decodeFailed("manifest exceeds provider structural bound")
        }
    }
}
