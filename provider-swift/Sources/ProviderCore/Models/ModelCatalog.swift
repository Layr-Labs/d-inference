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

// MARK: - Download progress tracking & rendering

/// Per-file progress state used by `DownloadProgressTracker`.
private struct FileProgress: Sendable {
    let label: String
    let expectedBytes: Int64
    var downloadedBytes: Int64 = 0
    var startTime: Date = Date()
    var completed: Bool = false
    var completionTime: Date?
    var destinationURL: URL?

    /// Bytes/second using elapsed wall time.
    var speed: Double {
        let elapsed = (completionTime ?? Date()).timeIntervalSince(startTime)
        guard elapsed > 0.1 else { return 0 }
        return Double(downloadedBytes) / elapsed
    }

    /// Estimated seconds remaining.
    var eta: Double? {
        guard speed > 0, expectedBytes > 0 else { return nil }
        let remaining = Double(expectedBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return remaining / speed
    }

    var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(expectedBytes))
    }
}

/// Delegate-based download tracker that provides incremental progress.
///
/// Each download task is registered with `register(taskID:label:expectedBytes:)`.
/// The delegate callbacks update shared state that `ProgressRenderer` reads.
/// Completed downloads are signalled via per-task continuations.
private final class DownloadProgressTracker: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Result of a single file download: the temporary location where
    /// URLSession wrote the file (must be moved before the delegate returns).
    struct DownloadResult {
        let location: URL
        let response: URLResponse
    }

    private let lock = NSLock()
    private var progressMap: [Int: FileProgress] = [:]  // taskIdentifier -> progress
    private var continuations: [Int: CheckedContinuation<DownloadResult, Error>] = [:]
    private var _allProgress: [FileProgress] = []

    /// Register a task so we can track its progress.
    func register(taskID: Int, label: String, expectedBytes: Int64) {
        lock.lock()
        progressMap[taskID] = FileProgress(label: label, expectedBytes: expectedBytes)
        rebuildSnapshot()
        lock.unlock()
    }

    /// Store the continuation that will be resumed when the download finishes.
    func setContinuation(_ cont: CheckedContinuation<DownloadResult, Error>, forTaskID taskID: Int) {
        lock.lock()
        continuations[taskID] = cont
        lock.unlock()
    }

    /// Thread-safe snapshot of all tracked file progress, ordered by
    /// registration time.
    var allProgress: [FileProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _allProgress
    }

    /// Whether all registered downloads have completed (or errored).
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !progressMap.isEmpty && progressMap.values.allSatisfy(\.completed)
    }

    private func rebuildSnapshot() {
        _allProgress = progressMap.keys.sorted().map { progressMap[$0]! }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let id = downloadTask.taskIdentifier
        if var p = progressMap[id] {
            p.downloadedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                // Update expected if the server tells us (e.g. after resume
                // partial content).  Keep original manifest value if server
                // returns -1.
            }
            progressMap[id] = p
            rebuildSnapshot()
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes the temp file when this callback returns.
        // Move it to a stable location so the continuation consumer can
        // process it.
        let stableLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-dl-\(downloadTask.taskIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: stableLocation)

        lock.lock()
        let id = downloadTask.taskIdentifier
        if var p = progressMap[id] {
            p.downloadedBytes = p.expectedBytes > 0 ? p.expectedBytes : p.downloadedBytes
            p.completed = true
            p.completionTime = Date()
            p.destinationURL = stableLocation
            progressMap[id] = p
            rebuildSnapshot()
        }
        let cont = continuations.removeValue(forKey: id)
        lock.unlock()

        let response = downloadTask.response ?? HTTPURLResponse(
            url: downloadTask.originalRequest?.url ?? URL(string: "about:blank")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        cont?.resume(returning: DownloadResult(location: stableLocation, response: response))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        lock.lock()
        let id = task.taskIdentifier
        if var p = progressMap[id] {
            p.completed = true
            p.completionTime = Date()
            progressMap[id] = p
            rebuildSnapshot()
        }
        let cont = continuations.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// Renders a multi-line progress display to the terminal using ANSI escape
/// codes. Falls back to simple per-file messages when stdout is not a TTY.
private final class ProgressRenderer: @unchecked Sendable {

    private let isTTY: Bool
    private var linesPrinted: Int = 0
    private let lock = NSLock()
    /// Set of labels already printed in non-TTY mode.
    private var printedLabels: Set<String> = []

    init() {
        self.isTTY = isatty(STDOUT_FILENO) != 0
    }

    /// Render a frame given the current file progress snapshot.
    func render(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }

        if !isTTY {
            renderPlain(files)
            return
        }
        renderANSI(files)
    }

    /// Final render: clear the progress area and print completion summary.
    func finish(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }

        if isTTY {
            // Move up and clear all lines.
            if linesPrinted > 0 {
                print("\u{1B}[\(linesPrinted)A", terminator: "")
                for _ in 0..<linesPrinted {
                    print("\u{1B}[2K")
                }
                print("\u{1B}[\(linesPrinted)A", terminator: "")
                linesPrinted = 0
            }
        }

        // Print final summary lines.
        for f in files {
            let totalStr = Self.formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            let elapsed = (f.completionTime ?? Date()).timeIntervalSince(f.startTime)
            let avgSpeed = elapsed > 0.1 ? Double(f.downloadedBytes) / elapsed : 0
            let speedStr = Self.formatSpeed(avgSpeed)
            let timeStr = Self.formatDuration(elapsed)
            print("  \u{2713} \(f.label)  \(totalStr)  \(speedStr)  \(timeStr)")
        }
    }

    // MARK: - ANSI rendering

    private func renderANSI(_ files: [FileProgress]) {
        // Move cursor up to overwrite previous render.
        if linesPrinted > 0 {
            print("\u{1B}[\(linesPrinted)A", terminator: "")
        }

        let termWidth = Self.terminalWidth()
        var lines = 0
        for f in files {
            print("\u{1B}[2K", terminator: "")  // Clear the line
            let line = Self.formatLine(f, termWidth: termWidth)
            print(line)
            lines += 1
        }
        linesPrinted = lines
        fflush(stdout)
    }

    private func renderPlain(_ files: [FileProgress]) {
        for f in files where f.completed && !printedLabels.contains(f.label) {
            printedLabels.insert(f.label)
            let totalStr = Self.formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            print("  \u{2713} \(f.label)  \(totalStr)")
        }
    }

    // MARK: - Line formatting

    private static func formatLine(_ f: FileProgress, termWidth: Int) -> String {
        if f.completed {
            let totalStr = formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            let elapsed = (f.completionTime ?? Date()).timeIntervalSince(f.startTime)
            let avgSpeed = elapsed > 0.1 ? Double(f.downloadedBytes) / elapsed : 0
            return "  \u{2713} \(f.label)  \(totalStr)  \(formatSpeed(avgSpeed))  done"
        }

        let pct = Int(f.fraction * 100)
        let dlStr = formatBytes(f.downloadedBytes)
        let totStr = formatBytes(f.expectedBytes)
        let speedStr = formatSpeed(f.speed)
        let etaStr: String
        if let eta = f.eta {
            etaStr = "ETA \(formatDuration(eta))"
        } else {
            etaStr = "---"
        }

        // Assemble the suffix: "  62%  2.1/4.8 GB  113 MB/s  ETA 24s"
        let suffix = "  \(String(format: "%3d", pct))%  \(dlStr)/\(totStr)  \(speedStr)  \(etaStr)"

        // Calculate bar width: total - label - prefix - suffix - brackets - spaces
        let labelMaxWidth = min(f.label.count, 45)
        let label = f.label.count > labelMaxWidth
            ? String(f.label.suffix(labelMaxWidth - 1)).padding(toLength: labelMaxWidth, withPad: " ", startingAt: 0)
            : f.label
        let prefix = "  \(label)  ["
        let postfix = "]\(suffix)"
        let barWidth = max(10, termWidth - prefix.count - postfix.count)

        let filled = Int(f.fraction * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)

        return "\(prefix)\(bar)\(postfix)"
    }

    // MARK: - Formatting helpers

    static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
        return String(format: "%.1f GB", b / 1_073_741_824)
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1_048_576 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        if bytesPerSec < 1_073_741_824 { return String(format: "%.0f MB/s", bytesPerSec / 1_048_576) }
        return String(format: "%.1f GB/s", bytesPerSec / 1_073_741_824)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }

    static func terminalWidth() -> Int {
        #if canImport(Darwin)
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        #endif
        return 80
    }
}

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

public enum ModelCatalogError: Error, CustomStringConvertible, LocalizedError, Sendable {
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

    public var errorDescription: String? { description }
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
        concurrency: Int = 4
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

    // MARK: - Resume-aware prefetch (background, no GPU load)

    /// Resolve the manifest for a catalog model via the same paths `download`
    /// uses (coordinator registry first, CDN fallback). Exposed so the prefetch
    /// coordinator can size total bytes / short-circuit before starting.
    public func resolveManifest(model: CatalogModel) async throws -> ModelManifest {
        if let catalogClient {
            return try await catalogClient.fetchManifest(modelID: model.id)
        }
        return try await fetchManifestFromCDN(model: model)
    }

    /// Download + verify a manifest model on disk WITHOUT loading it into GPU,
    /// resuming an interrupted prefetch instead of restarting from zero.
    ///
    /// Resume strategy: a STABLE per-model staging directory (keyed by the
    /// manifest's `r2Prefix`, not a random UUID) survives an interrupted
    /// prefetch. On re-entry, any file already present in staging that matches
    /// its manifest size AND SHA-256 is skipped; only missing/corrupt files are
    /// re-fetched. Per-file SHA is verified as each file lands; the aggregate
    /// hash is verified before the snapshot is published. The published snapshot
    /// is the same `snapshots/local` layout `download` produces, so
    /// `ModelScanner` discovers it immediately.
    ///
    /// `onByteProgress(done, total)` reports cumulative verified-on-disk bytes
    /// against the manifest total (already-present files count as done up front).
    public func prefetch(
        model: CatalogModel,
        manifest: ModelManifest,
        onByteProgress: (@Sendable (Int64, Int64) -> Void)? = nil
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

        // STABLE staging dir keyed by the manifest prefix so an interrupted
        // prefetch can resume. `r2Prefix` is path-like (e.g.
        // "v2/org__name/version"); flatten it to a single safe component.
        let stagingName = ".prefetch-staging-" + manifest.r2Prefix
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }

        // Classify each file once (hashing is expensive) into already-valid vs
        // still-needed. Reused for both progress seeding and the capacity check.
        let alreadyValid = jobs.map { Self.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256) }

        // Bytes already verified on disk (resumed files) count toward progress
        // immediately. `progress` is updated as each file completes.
        let total = manifest.totalSizeBytes
        let progress = PrefetchByteProgress()
        for (job, valid) in zip(jobs, alreadyValid) where valid {
            progress.add(job.file.sizeBytes)
        }
        onByteProgress?(progress.done, total)

        // Capacity pre-check must account for already-staged bytes: on a resumed
        // prefetch most files are present + valid, so we only need free space for
        // the files we still have to download. Demanding the FULL model size here
        // would spuriously fail a resume that has plenty of room for what remains.
        // Publishing is a same-volume move of the staging dir, so staged bytes
        // need no extra headroom.
        // Count bytes already saved in each file's resumable `.part` so a tight-
        // disk resume isn't rejected for lacking room equal to a whole shard when
        // the byte-resume below will only append the missing suffix via `Range`.
        let partBytes = jobs.map { fileSize($0.destination.appendingPathExtension("part")) }
        let remainingBytes = Self.remainingBytesToFetch(
            sizes: jobs.map(\.file.sizeBytes),
            alreadyValid: alreadyValid,
            partBytes: partBytes
        )
        try Self.ensureAvailableCapacity(at: snapshotsDir, requiredBytes: remainingBytes)

        // Sequential downloads (one at a time) so prefetch yields to inference
        // and never saturates bandwidth the way the foreground 4-way concurrent
        // download does. Each file: skip-if-valid, else fetch + verify.
        for job in jobs {
            try Task.checkCancellation()
            if Self.fileMatches(job.destination, size: job.file.sizeBytes, sha256: job.file.sha256) {
                continue
            }
            try await downloadManifestFileWithResume(job)
            progress.add(job.file.sizeBytes)
            onByteProgress?(progress.done, total)
        }

        try Task.checkCancellation()

        // Aggregate hash over the staged files (same ordering rule as download).
        // Every per-file SHA already verified above, so reaching here with a
        // mismatch means the staged files are internally valid but do not match
        // the claimed aggregate — i.e. the manifest's aggregate is wrong/corrupt.
        // If we keep staging, `fileMatches` would skip all files on every future
        // attempt and re-fail the aggregate forever (a permanent poison state).
        // Clear staging so a corrected manifest re-downloads cleanly. (Per-file
        // and network/transport failures throw BEFORE this point and deliberately
        // leave staging intact so they can resume — only the aggregate-mismatch
        // path clears it.)
        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }

        try Self.publishStagedSnapshot(stagingDir, to: cacheDir)
        try writeMainRef(for: model.id)
        // Staging was consumed by publishStagedSnapshot (moved/replaced); make a
        // best-effort cleanup in case the platform left a husk behind.
        try? FileManager.default.removeItem(at: stagingDir)
        onByteProgress?(total, total)
    }

    /// Whether a file at `url` already exists with the expected size and SHA-256.
    /// Used by prefetch resume to skip already-valid files.
    static func fileMatches(_ url: URL, size: Int64, sha256: String) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let onDisk = attrs[.size] as? Int64, onDisk == size else {
            return false
        }
        guard let digest = WeightHasher.hashSingleFile(at: url) else { return false }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == sha256.lowercased()
    }

    /// Download a single manifest file into its staging destination, resuming
    /// from a `.part` file when present, verifying size + SHA-256 before
    /// promoting to the final staged path. Reuses the resume-capable
    /// `downloadFile` helper (Range requests, Content-Range validation, retries).
    private func downloadManifestFileWithResume(
        _ job: (file: ManifestFile, destination: URL, url: String)
    ) async throws {
        let ok = try await downloadFile(
            from: job.url,
            to: job.destination,
            label: job.file.path,
            onProgress: nil,
            required: true,
            expectedSHA256: job.file.sha256.lowercased()
        )
        guard ok else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): required file could not be fetched")
        }
        let size = fileSize(job.destination)
        guard size == job.file.sizeBytes else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): size \(size) != manifest size \(job.file.sizeBytes)")
        }
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

        // STABLE staging dir keyed by the manifest prefix (NOT a random UUID) so an
        // interrupted foreground download resumes — already-completed files are
        // skipped instead of re-fetching the whole model. Same resume contract as
        // the background `prefetch` path: staging is kept on a transient failure
        // and cleared only on an aggregate-hash mismatch (poison) below.
        let stagingName = ".local-staging-" + manifest.r2Prefix
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }

        // Resume: skip files already staged + valid, and size the capacity
        // pre-check to only the bytes that remain (less anything already saved in a
        // `.part`) so a near-complete resume isn't rejected for lacking room equal
        // to the whole model. Only the not-yet-valid files are enqueued below.
        let alreadyValid = jobs.map { Self.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256) }
        // The foreground per-file downloader does a full GET (it does NOT byte-
        // resume — it deletes any stale `.part`), so only fully-valid files are
        // creditable here; every not-yet-valid file needs its full size. (Only the
        // background `prefetch` path byte-resumes and may credit `.part` bytes.)
        try Self.ensureAvailableCapacity(
            at: snapshotsDir,
            requiredBytes: Self.remainingBytesToFetch(
                sizes: jobs.map(\.file.sizeBytes), alreadyValid: alreadyValid
            )
        )
        let pending = zip(jobs, alreadyValid).filter { !$0.1 }.map(\.0)

        // Set up delegate-based session for progress tracking.
        let tracker = DownloadProgressTracker()
        let delegateSession = URLSession(
            configuration: urlSession.configuration,
            delegate: tracker,
            delegateQueue: nil
        )
        defer { delegateSession.finishTasksAndInvalidate() }

        let renderer = ProgressRenderer()

        // Start the render loop as a detached task.
        let renderTask = Task.detached { [renderer, tracker] in
            while !Task.isCancelled {
                renderer.render(tracker.allProgress)
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms
            }
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(concurrency, pending.count) {
                    let job = pending[next]
                    next += 1
                    group.addTask {
                        try await self.downloadManifestFileWithProgress(
                            job, tracker: tracker, session: delegateSession
                        )
                    }
                }

                while try await group.next() != nil {
                    if next < pending.count {
                        let job = pending[next]
                        next += 1
                        group.addTask {
                            try await self.downloadManifestFileWithProgress(
                                job, tracker: tracker, session: delegateSession
                            )
                        }
                    }
                }
            }

            // Stop the render loop and print final summary.
            renderTask.cancel()
            renderer.finish(tracker.allProgress)

            onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
        } catch {
            renderTask.cancel()
            // One last render so the user sees where things stopped.
            renderer.render(tracker.allProgress)
            // Keep staging ONLY if it holds resumable content (a completed file or
            // a `.part`); otherwise remove the empty husk so a first-file failure
            // doesn't leave a stray staging dir behind. (Size check only — a
            // promoted file is full-size + SHA-verified; size/SHA failures are
            // removed before this point.)
            let hasResumable = jobs.contains {
                fileSize($0.destination) == $0.file.sizeBytes
                    || fileSize($0.destination.appendingPathExtension("part")) > 0
            }
            if !hasResumable {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            throw error
        }

        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            // Internally-valid files that don't match the claimed aggregate = a
            // poisoned manifest; clear staging so a corrected manifest re-downloads
            // (otherwise skip-valid would re-fail the aggregate forever). Transient
            // per-file/network failures throw earlier and deliberately KEEP staging
            // so the next attempt resumes.
            try? FileManager.default.removeItem(at: stagingDir)
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }

        try Self.publishStagedSnapshot(stagingDir, to: cacheDir)
        try writeMainRef(for: model.id)
        // Staging was consumed by publishStagedSnapshot; best-effort husk cleanup.
        try? FileManager.default.removeItem(at: stagingDir)
    }

    /// Download a single manifest file using delegate-based URLSession for
    /// incremental progress reporting.
    private func downloadManifestFileWithProgress(
        _ job: (file: ManifestFile, destination: URL, url: String),
        tracker: DownloadProgressTracker,
        session: URLSession
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lastError: Error?
        for attempt in 1...3 {
            guard let url = URL(string: job.url) else {
                throw ModelCatalogError.downloadFailed("invalid URL: \(job.url)")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 6 * 60 * 60

            let task = session.downloadTask(with: request)
            tracker.register(
                taskID: task.taskIdentifier,
                label: job.file.path,
                expectedBytes: job.file.sizeBytes
            )

            do {
                let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadProgressTracker.DownloadResult, Error>) in
                    tracker.setContinuation(cont, forTaskID: task.taskIdentifier)
                    task.resume()
                }

                guard let http = result.response as? HTTPURLResponse else {
                    try? fm.removeItem(at: result.location)
                    throw ModelCatalogError.downloadFailed("\(job.file.path): unexpected response type")
                }
                guard (200..<300).contains(http.statusCode) else {
                    try? fm.removeItem(at: result.location)
                    throw ModelCatalogError.downloadFailed("\(job.file.path): HTTP \(http.statusCode)")
                }

                // Move temp file to .part for SHA verification.
                let partial = job.destination.appendingPathExtension("part")
                try? fm.removeItem(at: partial)
                try fm.moveItem(at: result.location, to: partial)

                // SHA-256 verification.
                let expectedSHA = job.file.sha256.lowercased()
                let actual = Self.sha256HexForVerification(of: partial)

                let size = fileSize(partial)
                guard actual == expectedSHA else {
                    try? fm.removeItem(at: partial)
                    throw ModelCatalogError.downloadFailed(
                        "\(job.file.path): SHA-256 mismatch (size=\(size), expected=\(expectedSHA.prefix(16))..., got=\(actual.prefix(16))...)"
                    )
                }

                guard size == job.file.sizeBytes else {
                    try? fm.removeItem(at: partial)
                    throw ModelCatalogError.downloadFailed(
                        "\(job.file.path): size \(size) != manifest size \(job.file.sizeBytes)"
                    )
                }

                // Promote .part to final destination.
                try? fm.removeItem(at: job.destination)
                try fm.moveItem(at: partial, to: job.destination)
                return

            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
            }
        }

        throw ModelCatalogError.downloadFailed(
            Self.downloadFailureMessage(label: job.file.path, error: lastError)
        )
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
            do {
                // True byte-level resume: stream the HTTP body straight to the
                // `.part` file as bytes arrive (appending when a `.part` prefix
                // already exists), so a mid-stream connection drop leaves the
                // received prefix on disk and the next attempt picks up where it
                // left off via a `Range` request — never restarting from zero.
                let ok = try await streamDownload(
                    from: url,
                    to: partial,
                    label: label,
                    required: required
                )
                guard ok else {
                    // Optional file that does not exist (404/403). `streamDownload`
                    // already removed any stale `.part`.
                    return false
                }

                if let expectedSHA256 {
                    let actual = Self.sha256HexForVerification(of: partial)
                    let size = fileSize(partial)
                    guard actual == expectedSHA256 else {
                        // The `.part` is corrupt (hash mismatch). Delete it so the
                        // next attempt re-fetches this file cleanly from byte 0
                        // rather than appending onto bad bytes forever.
                        try? fm.removeItem(at: partial)
                        throw ModelCatalogError.downloadFailed(
                            "\(label): SHA-256 mismatch (size=\(size), expected=\(expectedSHA256.prefix(16))…, got=\(actual.prefix(16))…)"
                        )
                    }
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: partial, to: destination)
                let downloaded = fileSize(destination)
                onProgress?(ProgressEvent(file: label, bytesDownloaded: downloaded, bytesTotal: downloaded))
                return true
            } catch is CancellationError {
                // Cancellation must propagate immediately and leave the `.part`
                // intact so a later run can resume it. Never retry.
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
            }
        }

        if required {
            throw ModelCatalogError.downloadFailed(Self.downloadFailureMessage(label: label, error: lastError))
        }
        return false
    }

    /// Stream an HTTP GET body incrementally into `partial`, appending to any
    /// bytes already present (true byte-level resume).
    ///
    /// Behavior:
    /// - If `partial` already has N bytes, sends `Range: bytes=N-`.
    /// - 206 with a `Content-Range` whose start == N → append to `partial`.
    /// - 200 (server ignored the Range / no range support) → truncate `partial`
    ///   and write from byte 0 (restart THIS file only).
    /// - 206 whose start != N (server resumed at the wrong offset) → truncate and
    ///   restart this file rather than append onto a mismatched stream.
    /// - 404/403 → remove `partial`; throw if `required`, else return false.
    /// - On a mid-stream transport drop, the bytes received so far stay in
    ///   `partial` and the error propagates (the caller retries with a fresh
    ///   `Range` request that appends the remainder).
    ///
    /// `Task.checkCancellation()` is checked between chunks so cancellation stops
    /// promptly and leaves a resumable `.part`.
    private func streamDownload(
        from url: URL,
        to partial: URL,
        label: String,
        required: Bool
    ) async throws -> Bool {
        let fm = FileManager.default
        let existingBytes = fileSize(partial)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Model shards are multi-GB files. A short request timeout causes
        // legitimate downloads to fail; the streaming byte sequence keeps the
        // connection alive across the whole transfer.
        request.timeoutInterval = 6 * 60 * 60
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (byteStream, response) = try await urlSession.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            try? fm.removeItem(at: partial)
            throw ModelCatalogError.downloadFailed("\(label): unexpected response type")
        }

        if http.statusCode == 404 || http.statusCode == 403 {
            try? fm.removeItem(at: partial)
            if required {
                throw ModelCatalogError.downloadFailed("\(label): HTTP \(http.statusCode)")
            }
            // Drain so the connection can be reused; ignore the bytes.
            for try await _ in byteStream {}
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            try? fm.removeItem(at: partial)
            throw ModelCatalogError.downloadFailed("\(label): HTTP \(http.statusCode)")
        }

        // Decide whether we append to the existing prefix or restart this file.
        var append = false
        if existingBytes > 0, http.statusCode == 206 {
            // Validate the server resumed at our offset before appending.
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let rangeStart = Self.parseContentRangeStart(contentRange),
               rangeStart == UInt64(existingBytes) {
                append = true
            }
        }
        // 200 (no range support) or an unverifiable/mismatched 206 → restart
        // THIS file only: truncate the stale prefix and write from byte 0.
        if !append {
            try? fm.removeItem(at: partial)
        }

        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil)
        }

        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: partial)
        } catch {
            throw ModelCatalogError.downloadFailed("\(label): could not open .part for writing (\(error.localizedDescription))")
        }
        defer { try? writer.close() }
        if append {
            try writer.seekToEnd()
        } else {
            try writer.truncate(atOffset: 0)
        }

        // Buffer chunks so we don't issue a write() syscall per byte. Flush as
        // each buffer fills (and at the end) so the bytes are durable on disk —
        // a mid-stream drop leaves a resumable prefix. CRITICAL: if the stream
        // errors mid-transfer (connection drop), flush whatever was buffered
        // before rethrowing so EVERY received byte lands in `.part` and the
        // retry resumes from exactly where the drop happened (never from zero).
        var buffer = Data()
        buffer.reserveCapacity(Self.streamFlushThreshold)
        var sinceCancelCheck = 0
        do {
            for try await byte in byteStream {
                buffer.append(byte)
                sinceCancelCheck += 1
                if buffer.count >= Self.streamFlushThreshold {
                    try writer.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                // Check cancellation periodically (every ~64KB) without paying
                // the cost on every single byte. The partial flush above means a
                // cancelled transfer still leaves a resumable .part.
                if sinceCancelCheck >= Self.streamFlushThreshold {
                    sinceCancelCheck = 0
                    if Task.isCancelled {
                        if !buffer.isEmpty { try writer.write(contentsOf: buffer) }
                        throw CancellationError()
                    }
                }
            }
        } catch {
            // Persist the prefix received before the drop, then propagate so the
            // caller retries with a `Range` request that appends the remainder.
            if !buffer.isEmpty { try? writer.write(contentsOf: buffer) }
            throw error
        }
        if !buffer.isEmpty {
            try writer.write(contentsOf: buffer)
        }
        return true
    }

    /// Flush the streaming download buffer to disk every 64 KB. Also the
    /// cadence at which cancellation is checked during streaming.
    private static let streamFlushThreshold = 65536

    /// Parse the start offset from a Content-Range header value.
    /// Expected format: "bytes 12345-67890/123456".
    private static func parseContentRangeStart(_ value: String) -> UInt64? {
        guard value.hasPrefix("bytes ") else { return nil }
        let afterBytes = value.dropFirst("bytes ".count)
        guard let dashIndex = afterBytes.firstIndex(of: "-") else { return nil }
        return UInt64(afterBytes[afterBytes.startIndex..<dashIndex])
    }

    private static func downloadFailureMessage(label: String, error: Error?) -> String {
        guard let error else { return "\(label): unknown error" }
        if case .downloadFailed(let detail) = error as? ModelCatalogError {
            return detail.hasPrefix("\(label):") ? detail : "\(label): \(detail)"
        }
        return "\(label): \(error.localizedDescription)"
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
        // Use WeightHasher.hashSingleFile which handles the NSFileProtection
        // fallback for files moved from URLSession temp locations.
        guard let digest = WeightHasher.hashSingleFile(at: url) else { return nil }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256HexForVerification(of url: URL) -> String {
        sha256HexForVerification(of: url, hasher: sha256Hex)
    }

    static func sha256HexForVerification(of url: URL, hasher: (URL) -> String?) -> String {
        hasher(url) ?? "<unreadable>"
    }

    /// Bytes still to fetch on a (possibly resumed) prefetch/download. For each
    /// file not already fully valid on disk, this is its size MINUS any bytes
    /// already saved in its resumable `.part` file — a byte-resume appends to that
    /// prefix via HTTP `Range`, so those bytes don't need re-downloading and must
    /// not be charged against free disk (otherwise a near-complete resume of a big
    /// shard is rejected for lacking room equal to the whole shard).
    /// `partBytes[i]` is the size of file i's `.part` (0 if none / not resumable);
    /// each term is floored at 0 so a stale over-long `.part` can't go negative.
    /// Omitting `partBytes` degrades to "sum of not-yet-valid file sizes".
    static func remainingBytesToFetch(sizes: [Int64], alreadyValid: [Bool], partBytes: [Int64] = []) -> Int64 {
        var total: Int64 = 0
        for i in sizes.indices {
            if i < alreadyValid.count, alreadyValid[i] { continue }
            let have = i < partBytes.count ? max(0, partBytes[i]) : 0
            total += max(0, sizes[i] - have)
        }
        return total
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

// MARK: - Prefetch byte-progress accumulator

/// Tiny thread-safe cumulative byte counter for prefetch progress. The
/// per-file downloads run sequentially, but the accumulator is `Sendable` so it
/// can be read from progress callbacks without data races.
private final class PrefetchByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Int64 = 0
    func add(_ bytes: Int64) { lock.lock(); _done += bytes; lock.unlock() }
    var done: Int64 { lock.lock(); defer { lock.unlock() }; return _done }
}

// MARK: - ModelPrefetcher abstraction

/// Abstraction over "make a model build available + verified on disk" so the
/// prefetch coordinator (Layer 3) can be unit-tested with an injected fake that
/// simulates success, resume, hash failure, and cancellation WITHOUT hitting
/// the network or downloading real multi-GB weights.
///
/// The real conformer (`ModelDownloader`) fetches the manifest from the
/// coordinator/CDN, downloads + resumes + verifies, and publishes the snapshot.
public protocol ModelPrefetcher: Sendable {
    /// Download (resuming if interrupted) and verify the model on disk without
    /// loading it into GPU. Reports cumulative verified bytes vs. total via
    /// `onByteProgress`. Throws on hash mismatch, fetch failure, or
    /// cancellation; returns normally only when the build is on disk and
    /// aggregate-hash-verified.
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (_ done: Int64, _ total: Int64) -> Void
    ) async throws
}

/// Production `ModelPrefetcher` backed by the coordinator catalog + R2 CDN.
///
/// Resolves the catalog entry (for `r2Prefix`/`aggregateSHA256`), then the
/// manifest, then runs the resume-aware verified download. A short-circuit for
/// "already on disk and valid" is handled one layer up (the prefetch
/// coordinator) so this type stays a thin IO conformer.
public struct CatalogModelPrefetcher: ModelPrefetcher {
    private let catalogClient: ModelCatalogClient
    private let downloader: ModelDownloader

    public init(coordinatorURL: String, urlSession: URLSession = .shared) {
        let client = ModelCatalogClient(coordinatorURL: coordinatorURL, urlSession: urlSession)
        self.catalogClient = client
        self.downloader = ModelDownloader(urlSession: urlSession, catalogClient: client)
    }

    public init(catalogClient: ModelCatalogClient, downloader: ModelDownloader) {
        self.catalogClient = catalogClient
        self.downloader = downloader
    }

    public func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (_ done: Int64, _ total: Int64) -> Void
    ) async throws {
        let catalog = try await catalogClient.fetchCatalog()
        guard let model = catalog.first(where: { $0.id == modelID }) else {
            throw ModelCatalogError.modelNotInCatalog(modelID)
        }
        guard model.r2Prefix != nil, model.aggregateSHA256 != nil else {
            throw ModelCatalogError.downloadFailed(
                "model '\(modelID)' has no manifest (r2_prefix/aggregate_sha256); cannot prefetch"
            )
        }
        let manifest = try await downloader.resolveManifest(model: model)
        try await downloader.prefetch(model: model, manifest: manifest, onByteProgress: onByteProgress)
    }
}
