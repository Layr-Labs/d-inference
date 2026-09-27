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

        let response: CatalogResponse = try await fetchJSON(
            from: url, maximumBytes: Self.maximumCatalogResponseBytes,
            responseName: "catalog response", validate: Self.validateCatalogBounds)
        return CatalogSnapshot(models: response.models, aliases: response.aliases ?? [])
    }

    /// Fetch the active registry manifest for a model. Model IDs can contain
    /// `/`, so the ID is percent-encoded as one path suffix.
    public func fetchManifest(modelID: String) async throws -> ModelManifest {
        guard let escapedID = Self.escapeModelIDForPath(modelID),
              let url = URL(string: "\(coordinatorURL)/v1/models/catalog/manifest/\(escapedID)")
        else {
            throw ModelCatalogError.unreachable("invalid manifest URL")
        }

        return try await fetchJSON(
            from: url, maximumBytes: Self.maximumManifestResponseBytes,
            responseName: "manifest response", decoder: Self.manifestDecoder,
            validate: Self.validateManifestBounds)
    }

    /// Both endpoints use the same bounded transport and error mapping. Keep
    /// HTTP rejection before lexical/Codable checks so error bodies retain their
    /// original status; structural checks still run only after safe decoding.
    private func fetchJSON<Response: Decodable>(
        from url: URL, maximumBytes: Int, responseName: String,
        decoder: JSONDecoder = JSONDecoder(),
        validate: (Response) throws -> Void
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(
                for: request, maximumBytes: maximumBytes, responseName: responseName)
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            try Self.validateJSONLexicalBounds(data, responseName: responseName)
            let decoded = try decoder.decode(Response.self, from: data)
            try validate(decoded)
            return decoded
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

}
