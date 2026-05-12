/// ModelCatalog -- coordinator-side catalog client and on-disk model
/// download / removal.
///
/// The coordinator owns the canonical catalog at `GET /v1/models/catalog`.
/// Providers fetch it to know which model IDs are servable; the same
/// endpoint is consumed by the console UI and the `darkbloom models`
/// CLI verb.
///
/// Downloads pull from R2 directly (the coordinator never fronts model
/// weights). The model lives in the standard HuggingFace cache layout
/// at `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{hash}/`,
/// matching what `ModelScanner` already discovers.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Catalog model

public struct CatalogModel: Codable, Sendable, Equatable {
    public let id: String
    public let s3Name: String
    public let displayName: String
    public let modelType: String
    public let sizeGb: Double
    public let architecture: String?
    public let description: String?
    public let minRamGb: Int?
    public let active: Bool?
    public let weightHash: String?

    enum CodingKeys: String, CodingKey {
        case id
        case s3Name = "s3_name"
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGb = "size_gb"
        case architecture
        case description
        case minRamGb = "min_ram_gb"
        case active
        case weightHash = "weight_hash"
    }

    public init(
        id: String,
        s3Name: String,
        displayName: String,
        modelType: String = "text",
        sizeGb: Double,
        architecture: String? = nil,
        description: String? = nil,
        minRamGb: Int? = nil,
        active: Bool? = nil,
        weightHash: String? = nil
    ) {
        self.id = id
        self.s3Name = s3Name
        self.displayName = displayName
        self.modelType = modelType
        self.sizeGb = sizeGb
        self.architecture = architecture
        self.description = description
        self.minRamGb = minRamGb
        self.active = active
        self.weightHash = weightHash
    }
}

private struct CatalogResponse: Codable {
    let models: [CatalogModel]
}

// MARK: - Errors

public enum ModelCatalogError: Error, CustomStringConvertible, Sendable {
    case unreachable(String)
    case http(Int, String)
    case decodeFailed(String)
    case modelNotInCatalog(String)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .unreachable(let d):           "coordinator unreachable: \(d)"
        case .http(let code, let body):     "coordinator HTTP \(code): \(body)"
        case .decodeFailed(let d):          "could not decode catalog response: \(d)"
        case .modelNotInCatalog(let id):    "model '\(id)' is not in the coordinator catalog"
        case .downloadFailed(let d):        "download failed: \(d)"
        }
    }
}

// MARK: - Catalog client

public struct ModelCatalogClient: Sendable {

    private let coordinatorURL: String

    public init(coordinatorURL: String) {
        self.coordinatorURL = coordinatorHTTPBase(coordinatorURL)
    }

    /// Fetch the active catalog from the coordinator. `typeFilter` mirrors
    /// the coordinator's `?type=` query parameter (e.g. "text").
    public func fetchCatalog(typeFilter: String? = nil) async throws -> [CatalogModel] {
        var components = URLComponents(string: "\(coordinatorURL)/v1/models/catalog")!
        if let typeFilter, !typeFilter.isEmpty {
            components.queryItems = [URLQueryItem(name: "type", value: typeFilter)]
        }
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ModelCatalogError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
            return decoded.models
        } catch {
            throw ModelCatalogError.decodeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Downloader

public struct ModelDownloader: Sendable {

    public struct ProgressEvent: Sendable {
        public let file: String
        public let bytesDownloaded: Int64
        public let bytesTotal: Int64?
    }

    /// CDN root for model artifacts. The provider used to read this from
    /// `DEFAULT_R2_CDN_URL` baked at compile time; the Swift provider keeps
    /// the same prod default, override with the `DARKBLOOM_R2_CDN_URL` env
    /// var or the `r2CDNURL` init arg.
    public static let defaultR2CDNURL = "https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev"

    private let r2CDNURL: String
    private let urlSession: URLSession

    public init(r2CDNURL: String? = nil, urlSession: URLSession = .shared) {
        if let r2CDNURL { self.r2CDNURL = r2CDNURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else if let env = ProcessInfo.processInfo.environment["DARKBLOOM_R2_CDN_URL"], !env.isEmpty {
            self.r2CDNURL = env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            self.r2CDNURL = ModelDownloader.defaultR2CDNURL
        }
        self.urlSession = urlSession
    }

    /// Download a catalog model into the local HuggingFace cache.
    ///
    /// Tries (in order):
    ///   1. `${R2_CDN}/${s3_name}/config.json` -- the existence smoke test
    ///   2. tokenizer files (best-effort, missing files are fine)
    ///   3. `model.safetensors` if present, else
    ///   4. `model.safetensors.index.json` + each shard listed inside
    ///
    /// On success, the model is laid out under
    /// `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/local/`
    /// with a `refs/main` pointer so `ModelScanner` discovers it the next
    /// time `darkbloom status` runs.
    public func download(
        model: CatalogModel,
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws {
        let cacheDir = Self.cacheSnapshotDirectory(for: model.id)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let base = "\(r2CDNURL)/\(model.s3Name)"

        // 1. config.json (smoke-test the model exists on the CDN).
        try await downloadFile(
            from: "\(base)/config.json",
            to: cacheDir.appendingPathComponent("config.json"),
            label: "config.json",
            onProgress: onProgress,
            required: true
        )

        // 2. tokenizer files. Best-effort.
        for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "tokenizer.model", "chat_template.jinja"] {
            _ = try? await downloadFile(
                from: "\(base)/\(name)",
                to: cacheDir.appendingPathComponent(name),
                label: name,
                onProgress: onProgress,
                required: false
            )
        }

        // 3. Single safetensors? If a HEAD request returns 200 we go that route.
        if try await urlExists("\(base)/model.safetensors") {
            try await downloadFile(
                from: "\(base)/model.safetensors",
                to: cacheDir.appendingPathComponent("model.safetensors"),
                label: "model.safetensors",
                onProgress: onProgress,
                required: true
            )
        } else {
            // 4. Sharded model. Pull the index, then each shard listed in
            // `weight_map`.
            let indexPath = cacheDir.appendingPathComponent("model.safetensors.index.json")
            try await downloadFile(
                from: "\(base)/model.safetensors.index.json",
                to: indexPath,
                label: "model.safetensors.index.json",
                onProgress: onProgress,
                required: true
            )
            let shards = try Self.parseShardNames(indexPath: indexPath)
            for shard in shards {
                try await downloadFile(
                    from: "\(base)/\(shard)",
                    to: cacheDir.appendingPathComponent(shard),
                    label: shard,
                    onProgress: onProgress,
                    required: true
                )
            }
        }

        try writeMainRef(for: model.id)
    }

    /// Remove a downloaded model from the cache. Returns true if anything was
    /// removed, false if the model was not present.
    @discardableResult
    public static func remove(modelID: String) throws -> Bool {
        let modelDir = cacheModelDirectory(for: modelID)
        guard FileManager.default.fileExists(atPath: modelDir.path) else { return false }
        try FileManager.default.removeItem(at: modelDir)
        return true
    }

    // MARK: - Internals

    public static func cacheModelDirectory(for modelID: String) -> URL {
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .appendingPathComponent("models--\(safe)", isDirectory: true)
    }

    static func cacheSnapshotDirectory(for modelID: String) -> URL {
        cacheModelDirectory(for: modelID)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
    }

    static func parseShardNames(indexPath: URL) throws -> [String] {
        let data = try Data(contentsOf: indexPath)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any],
              let weightMap = dict["weight_map"] as? [String: String]
        else {
            throw ModelCatalogError.downloadFailed(
                "model.safetensors.index.json missing weight_map"
            )
        }
        let unique = Set(weightMap.values)
        return unique.sorted()
    }

    internal func downloadFileForTesting(
        from urlString: String,
        to destination: URL,
        label: String = "test.bin",
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil,
        required: Bool = true
    ) async throws -> Bool {
        try await downloadFile(
            from: urlString,
            to: destination,
            label: label,
            onProgress: onProgress,
            required: required
        )
    }

    private func urlExists(_ urlString: String) async throws -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            let (_, response) = try await urlSession.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    @discardableResult
    private func downloadFile(
        from urlString: String,
        to destination: URL,
        label: String,
        onProgress: (@Sendable (ProgressEvent) -> Void)?,
        required: Bool
    ) async throws -> Bool {
        guard let url = URL(string: urlString) else {
            if required { throw ModelCatalogError.downloadFailed("invalid URL: \(urlString)") }
            return false
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")

        var lastError: Error?
        for attempt in 1...3 {
            var existingBytes = fileSize(partial)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            }

            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ModelCatalogError.downloadFailed("\(label): unexpected response type")
                }

                if http.statusCode == 404 || http.statusCode == 403 {
                    if required {
                        throw ModelCatalogError.downloadFailed("\(label): HTTP \(http.statusCode)")
                    }
                    return false
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ModelCatalogError.downloadFailed("\(label): HTTP \(http.statusCode)")
                }

                let appending = existingBytes > 0 && http.statusCode == 206
                if existingBytes > 0 && !appending {
                    try? fm.removeItem(at: partial)
                    existingBytes = 0
                }
                if !fm.fileExists(atPath: partial.path) {
                    fm.createFile(atPath: partial.path, contents: nil)
                }

                guard let handle = try? FileHandle(forWritingTo: partial) else {
                    throw ModelCatalogError.downloadFailed("\(label): could not open destination")
                }
                defer { try? handle.close() }
                if appending {
                    try handle.seekToEnd()
                } else {
                    try handle.truncate(atOffset: 0)
                }

                let expectedLength = http.expectedContentLength >= 0 ? http.expectedContentLength : -1
                let total = expectedLength >= 0 ? existingBytes + expectedLength : nil
                var downloaded = existingBytes
                var buffer = Data()
                buffer.reserveCapacity(1_048_576)
                var nextProgress = downloaded + 64 * 1_048_576

                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1_048_576 {
                        try handle.write(contentsOf: buffer)
                        downloaded += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if downloaded >= nextProgress {
                            onProgress?(ProgressEvent(file: label, bytesDownloaded: downloaded, bytesTotal: total))
                            nextProgress = downloaded + 64 * 1_048_576
                        }
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    downloaded += Int64(buffer.count)
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: partial, to: destination)
                onProgress?(ProgressEvent(file: label, bytesDownloaded: downloaded, bytesTotal: total ?? downloaded))
                return true
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
            }
        }

        if required {
            throw ModelCatalogError.downloadFailed("\(label): \(lastError?.localizedDescription ?? "unknown error")")
        }
        return false
    }

    private func writeMainRef(for modelID: String) throws {
        let modelDir = Self.cacheModelDirectory(for: modelID)
        let refsDir = modelDir.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try "local".write(
            to: refsDir.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

}
