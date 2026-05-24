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
import Crypto
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
    public let version: String?
    public let r2Prefix: String?
    public let aggregateSHA256: String?
    public let totalSizeBytes: Int64?
    public let fileCount: Int?
    public let family: String?
    public let quantization: String?
    public let maxContextLength: Int?
    public let maxOutputLength: Int?
    public let capabilities: [String]?
    public let runtimeParameters: [String: JSONValue]?
    public let metadata: [String: JSONValue]?

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
        case version
        case r2Prefix = "r2_prefix"
        case aggregateSHA256 = "aggregate_sha256"
        case totalSizeBytes = "total_size_bytes"
        case fileCount = "file_count"
        case family
        case quantization
        case maxContextLength = "max_context_length"
        case maxOutputLength = "max_output_length"
        case capabilities
        case runtimeParameters = "runtime_parameters"
        case metadata
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
        weightHash: String? = nil,
        version: String? = nil,
        r2Prefix: String? = nil,
        aggregateSHA256: String? = nil,
        totalSizeBytes: Int64? = nil,
        fileCount: Int? = nil,
        family: String? = nil,
        quantization: String? = nil,
        maxContextLength: Int? = nil,
        maxOutputLength: Int? = nil,
        capabilities: [String]? = nil,
        runtimeParameters: [String: JSONValue]? = nil,
        metadata: [String: JSONValue]? = nil
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
        self.version = version
        self.r2Prefix = r2Prefix
        self.aggregateSHA256 = aggregateSHA256
        self.totalSizeBytes = totalSizeBytes
        self.fileCount = fileCount
        self.family = family
        self.quantization = quantization
        self.maxContextLength = maxContextLength
        self.maxOutputLength = maxOutputLength
        self.capabilities = capabilities
        self.runtimeParameters = runtimeParameters
        self.metadata = metadata
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
    private let urlSession: URLSession

    public init(coordinatorURL: String, urlSession: URLSession = .shared) {
        self.coordinatorURL = coordinatorHTTPBase(coordinatorURL)
        self.urlSession = urlSession
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
            (data, response) = try await urlSession.data(for: request)
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
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ModelCatalogError.unreachable(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try Self.manifestDecoder.decode(ModelManifest.self, from: data)
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
}

// MARK: - Downloader

public struct ModelDownloader: Sendable {

    public struct ProgressEvent: Sendable {
        public let file: String
        public let bytesDownloaded: Int64
        public let bytesTotal: Int64?
    }

    /// CDN root for model artifacts. Override with `DARKBLOOM_R2_CDN_URL` for
    /// transition/testing against alternate buckets.
    public static let defaultR2CDNURL = "https://models.darkbloom.ai"

    private let r2CDNURL: String
    private let urlSession: URLSession
    private let catalogClient: ModelCatalogClient?
    private let concurrency: Int

    public init(
        r2CDNURL: String? = nil,
        urlSession: URLSession = .shared,
        catalogClient: ModelCatalogClient? = nil,
        concurrency: Int = 8
    ) {
        if let r2CDNURL { self.r2CDNURL = r2CDNURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        else if let env = ProcessInfo.processInfo.environment["DARKBLOOM_R2_CDN_URL"], !env.isEmpty {
            self.r2CDNURL = env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            self.r2CDNURL = ModelDownloader.defaultR2CDNURL
        }
        self.urlSession = urlSession
        self.catalogClient = catalogClient
        self.concurrency = max(1, concurrency)
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
        if model.r2Prefix != nil, model.aggregateSHA256 != nil {
            let manifest: ModelManifest
            if let catalogClient {
                manifest = try await catalogClient.fetchManifest(modelID: model.id)
            } else {
                manifest = try await fetchManifestFromCDN(model: model)
            }
            try await downloadManifestModel(model: model, manifest: manifest, onProgress: onProgress)
            return
        }

        try await downloadLegacyModelFromCDN(model: model, onProgress: onProgress)
    }

    private func fetchManifestFromCDN(model: CatalogModel) async throws -> ModelManifest {
        guard let r2Prefix = model.r2Prefix else {
            throw ModelCatalogError.downloadFailed("model missing r2_prefix")
        }
        let urlString = "\(r2CDNURL)/\(Self.escapeR2Path(r2Prefix))/manifest.json"
        guard let url = URL(string: urlString) else {
            throw ModelCatalogError.downloadFailed("invalid manifest URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.downloadFailed("manifest.json: HTTP \(http.statusCode)")
        }

        do {
            return try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json decode failed: \(error.localizedDescription)")
        }
    }

    private func downloadLegacyModelFromCDN(
        model: CatalogModel,
        onProgress: (@Sendable (ProgressEvent) -> Void)?
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

    private func downloadManifestModel(
        model: CatalogModel,
        manifest: ModelManifest,
        onProgress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws {
        guard manifest.modelID == model.id else {
            throw ModelCatalogError.downloadFailed("manifest model_id \(manifest.modelID) does not match catalog id \(model.id)")
        }
        guard manifest.files.count == manifest.fileCount else {
            throw ModelCatalogError.downloadFailed("manifest file_count \(manifest.fileCount) does not match files array")
        }
        guard !manifest.files.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest contains no files")
        }
        if let aggregate = model.aggregateSHA256, aggregate != manifest.aggregateSHA256 {
            throw ModelCatalogError.downloadFailed("catalog aggregate hash does not match manifest")
        }
        if let prefix = model.r2Prefix, prefix != manifest.r2Prefix {
            throw ModelCatalogError.downloadFailed("catalog r2_prefix does not match manifest")
        }

        let cacheDir = Self.cacheSnapshotDirectory(for: model.id)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try Self.ensureAvailableCapacity(at: snapshotsDir, requiredBytes: manifest.totalSizeBytes)

        let stagingDir = snapshotsDir.appendingPathComponent(".local-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: stagingDir)
            }
        }

        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(concurrency, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { try await downloadManifestFile(job, onProgress: onProgress) }
            }

            while try await group.next() != nil {
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { try await downloadManifestFile(job, onProgress: onProgress) }
                }
            }
        }

        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }

        try Self.publishStagedSnapshot(stagingDir, to: cacheDir)
        try writeMainRef(for: model.id)
        completed = true
    }

    private func downloadManifestFile(
        _ job: (file: ManifestFile, destination: URL, url: String),
        onProgress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws {
        onProgress?(ProgressEvent(file: job.file.path, bytesDownloaded: 0, bytesTotal: job.file.sizeBytes))
        try await downloadFile(
            from: job.url,
            to: job.destination,
            label: job.file.path,
            onProgress: onProgress,
            required: true,
            expectedSHA256: job.file.sha256.lowercased()
        )
        let size = fileSize(job.destination)
        guard size == job.file.sizeBytes else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): size \(size) != manifest size \(job.file.sizeBytes)")
        }
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

    static func validatedManifestRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest contains empty file path")
        }
        guard !path.hasPrefix("/"), !path.contains("\\") else {
            throw ModelCatalogError.downloadFailed("unsafe manifest path: \(path)")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelCatalogError.downloadFailed("unsafe manifest path: \(path)")
        }
        return path
    }

    static func escapeR2Path(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
            }
            .joined(separator: "/")
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
            required: required,
            expectedSHA256: nil
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
        required: Bool,
        expectedSHA256: String? = nil
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
                if http.statusCode == 416, existingBytes > 0 {
                    // Stale .part is already complete or inconsistent with the
                    // current object. Delete it and retry once from byte 0.
                    try? fm.removeItem(at: partial)
                    existingBytes = 0
                    throw ModelCatalogError.downloadFailed("\(label): stale partial download")
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
                try handle.close()
                if let expectedSHA256 {
                    guard let actual = Self.sha256Hex(of: partial), actual == expectedSHA256 else {
                        try? fm.removeItem(at: partial)
                        throw ModelCatalogError.downloadFailed("\(label): SHA-256 mismatch")
                    }
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

    private static func publishStagedSnapshot(_ stagingDir: URL, to cacheDir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDir.path) {
            _ = try fm.replaceItemAt(cacheDir, withItemAt: stagingDir)
        } else {
            try fm.moveItem(at: stagingDir, to: cacheDir)
        }
    }

    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 65536) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureAvailableCapacity(at directory: URL, requiredBytes: Int64) throws {
        guard requiredBytes > 0 else { return }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        guard available <= 0 || available >= requiredBytes else {
            throw ModelCatalogError.downloadFailed(
                "insufficient disk space: need \(requiredBytes) bytes, available \(available) bytes"
            )
        }
    }

}
