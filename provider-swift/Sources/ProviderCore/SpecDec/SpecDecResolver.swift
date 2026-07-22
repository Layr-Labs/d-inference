import Foundation
import Logging
import ProviderCoreFoundation

private actor SpecDecResolutionCoordinator {
    static let shared = SpecDecResolutionCoordinator()

    struct Key: Sendable, Hashable {
        let storeRoot: String
        let cdnIdentity: String
        let reference: SpecDecArtifactReference
        let allowDownload: Bool
    }

    private struct Inflight {
        let id: UUID
        let task: Task<SpecDecResolution, Never>
        let keepAlive: Bool
        var waiters: [UUID: CheckedContinuation<SpecDecResolution, Never>]
    }
    private var inflight: [Key: Inflight] = [:]
    private let maximumInflight = 4

    func run(
        key: Key,
        operation: @escaping @Sendable () async -> SpecDecResolution
    ) async -> SpecDecResolution {
        let inflightID: UUID
        if let existing = inflight[key] {
            inflightID = existing.id
        } else {
            guard inflight.count < maximumInflight else {
                return .fallback(.artifactNotCached, detail: "MTP prefetch concurrency limit reached")
            }
            let id = UUID()
            let task = Task {
                let result = await operation()
                self.finished(key: key, id: id, result: result)
                return result
            }
            inflight[key] = Inflight(
                id: id, task: task, keepAlive: false, waiters: [:])
            inflightID = id
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var current = inflight[key], current.id == inflightID else {
                    continuation.resume(returning: .fallback(
                        .fileDownloadFailed,
                        detail: "MTP prefetch ended before waiter registration"))
                    return
                }
                current.waiters[waiterID] = continuation
                inflight[key] = current
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key, inflightID: inflightID, waiterID: waiterID)
            }
        }
    }

    func schedule(
        key: Key,
        operation: @escaping @Sendable () async -> SpecDecResolution
    ) {
        guard inflight[key] == nil, inflight.count < maximumInflight else { return }
        let id = UUID()
        let task = Task {
            let result = await operation()
            self.finished(key: key, id: id, result: result)
            return result
        }
        inflight[key] = Inflight(
            id: id, task: task, keepAlive: true, waiters: [:])
    }

    private func cancelWaiter(
        key: Key,
        inflightID: UUID,
        waiterID: UUID
    ) {
        guard var current = inflight[key], current.id == inflightID,
            let continuation = current.waiters.removeValue(forKey: waiterID)
        else { return }
        if current.waiters.isEmpty, !current.keepAlive {
            inflight.removeValue(forKey: key)
            current.task.cancel()
        } else {
            inflight[key] = current
        }
        continuation.resume(returning: .fallback(
            .fileDownloadFailed, detail: "MTP prefetch was cancelled"))
    }

    private func finished(
        key: Key,
        id: UUID,
        result: SpecDecResolution
    ) {
        guard let current = inflight[key], current.id == id else { return }
        inflight.removeValue(forKey: key)
        for continuation in current.waiters.values {
            continuation.resume(returning: result)
        }
    }
}

public struct SpecDecResolver: Sendable {
    private let storeRoot: URL
    private let downloader: ModelDownloader
    private let prefetchTimeout: Duration
    private static let logger = Logger(label: "darkbloom.SpecDecResolver")

    public init(
        storeRoot: URL? = nil,
        cdnBaseURL: String? = nil,
        urlSession: URLSession = .shared,
        prefetchTimeout: Duration = .seconds(120)
    ) {
        self.storeRoot = storeRoot ?? SpecDecStore.defaultRoot()
        self.downloader = ModelDownloader(r2CDNURL: cdnBaseURL, urlSession: urlSession)
        self.prefetchTimeout = prefetchTimeout
    }

    public static func specDecR2Prefix(for model: CatalogModel) -> String? {
        guard case .success(let reference) = SpecDecMetadata.reference(for: model) else { return nil }
        return reference.r2Prefix
    }

    func resolve(model: CatalogModel, allowDownload: Bool) async -> SpecDecResolution {
        let reference: SpecDecArtifactReference
        switch SpecDecMetadata.reference(for: model) {
        case .success(let value): reference = value
        case .failure(let error): return .fallback(error.reason, detail: error.description)
        }
        let cached = resolveCached(reference: reference)
        guard cached.reason == .artifactNotCached, allowDownload else { return cached }

        let key = resolutionKey(reference: reference, allowDownload: true)
        await SpecDecResolutionCoordinator.shared.schedule(key: key) {
            await boundedDownload(reference: reference)
        }
        return cached
    }

    /// Explicit prefetch lifecycle used by the background artifact funnel and
    /// tests. Callers that are loading a target use `resolve`, which only checks
    /// verified local state and schedules this work without awaiting it.
    func prefetch(model: CatalogModel) async -> SpecDecResolution {
        let reference: SpecDecArtifactReference
        switch SpecDecMetadata.reference(for: model) {
        case .success(let value): reference = value
        case .failure(let error): return .fallback(error.reason, detail: error.description)
        }
        let cached = resolveCached(reference: reference)
        guard cached.reason == .artifactNotCached else { return cached }
        let key = resolutionKey(reference: reference, allowDownload: true)
        return await SpecDecResolutionCoordinator.shared.run(key: key) {
            await boundedDownload(reference: reference)
        }
    }

    /// URL-only convenience surface. Cold downloads are scheduled and return
    /// nil immediately; a later call observes the verified publication.
    public func drafterDirectory(for model: CatalogModel, allowDownload: Bool) async -> URL? {
        let result = await resolve(model: model, allowDownload: allowDownload)
        if let reason = result.reason {
            let message = "spec-dec: model \(model.id) fallback reason=\(reason.rawValue)"
                + (result.detail.map { " detail=\($0)" } ?? "")
            Self.logger.warning("\(message)")
        }
        return result.artifact?.directory
    }

    private func resolveCached(reference: SpecDecArtifactReference) -> SpecDecResolution {
        let artifactDir = SpecDecStore.artifactDirectory(
            root: storeRoot, r2Prefix: reference.r2Prefix)
        if FileManager.default.fileExists(atPath: artifactDir.path) {
            switch SpecDecStore.verifyPublishedArtifact(at: artifactDir, reference: reference) {
            case .success(let verification):
                return .resolved(artifact(from: verification, directory: artifactDir, reference: reference))
            case .failure(let error):
                // Immutable publications are never replaced in place. A warm
                // corruption is observable and target decode remains available.
                return .fallback(.warmArtifactCorrupt, detail: error.description)
            }
        }
        return .fallback(.artifactNotCached)
    }

    private func downloadAndPublish(
        reference: SpecDecArtifactReference
    ) async -> SpecDecResolution {
        let artifactDir = SpecDecStore.artifactDirectory(
            root: storeRoot, r2Prefix: reference.r2Prefix)
        // A task can sit behind the bounded coordinator while another process
        // publishes the artifact. Recheck before opening a network transfer.
        let cached = resolveCached(reference: reference)
        guard cached.reason == .artifactNotCached else { return cached }
        do {
            try FileManager.default.createDirectory(
                at: storeRoot, withIntermediateDirectories: true)
            let staging = SpecDecStore.stagingDirectory(
                root: storeRoot, r2Prefix: reference.r2Prefix)
            defer { try? FileManager.default.removeItem(at: staging) }
            _ = try await downloadArtifact(reference: reference, staging: staging)
            switch SpecDecStore.publishImmutable(
                staging: staging, destination: artifactDir, reference: reference)
            {
            case .success(let published):
                return .resolved(artifact(from: published, directory: artifactDir, reference: reference))
            case .failure(let error):
                return .fallback(error.reason, detail: error.description)
            }
        } catch let failure as ResolverFailure {
            return .fallback(failure.reason, detail: failure.description)
        } catch {
            return .fallback(.fileDownloadFailed, detail: error.localizedDescription)
        }
    }

    private func boundedDownload(
        reference: SpecDecArtifactReference
    ) async -> SpecDecResolution {
        let started = ContinuousClock.now
        let result = await withTaskGroup(of: SpecDecResolution.self) { group in
            group.addTask {
                await downloadAndPublish(reference: reference)
            }
            group.addTask {
                do {
                    try await taskSleep(prefetchTimeout)
                    return .fallback(
                        .downloadTimedOut,
                        detail: "MTP prefetch exceeded its owned deadline")
                } catch {
                    return .fallback(
                        .downloadCancelled,
                        detail: "MTP prefetch was cancelled")
                }
            }
            let result = await group.next()
                ?? .fallback(.fileDownloadFailed, detail: "MTP prefetch ended without a result")
            group.cancelAll()
            return result
        }
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int64(max(
            0,
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15))
        Self.logger.info(
            "spec-dec: revision=\(reference.revision) download_verify_ms=\(milliseconds) result=\(result.reason?.rawValue ?? "ready")")
        return result
    }

    private func resolutionKey(
        reference: SpecDecArtifactReference,
        allowDownload: Bool
    ) -> SpecDecResolutionCoordinator.Key {
        .init(
            storeRoot: storeRoot.standardizedFileURL.path,
            cdnIdentity: downloader.r2CDNURL,
            reference: reference,
            allowDownload: allowDownload)
    }

    private func downloadArtifact(
        reference: SpecDecArtifactReference,
        staging: URL
    ) async throws -> SpecDecStore.Verification {
        let (manifest, manifestData) = try await fetchManifest(reference: reference)
        switch SpecDecStore.validateManifest(manifest, data: manifestData, reference: reference) {
        case .failure(let error): throw ResolverFailure(reason: error.reason, description: error.description)
        case .success: break
        }

        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let jobs = manifest.files.map { file in
            (
                file: file,
                destination: staging.appendingPathComponent(file.path, isDirectory: false),
                url: "\(downloader.r2CDNURL)/\(ModelDownloader.escapeR2Path(reference.r2Prefix))/\(ModelDownloader.escapeR2Path(file.path))"
            )
        }
        try ModelDownloader.ensureAvailableCapacity(
            at: storeRoot, requiredBytes: manifest.totalSizeBytes)

        for job in jobs {
            do {
                try await downloader.downloadManifestFileWithResume(job)
            } catch {
                let detail = String(describing: error)
                let reason: MTPFallbackReason = detail.contains("SHA-256 mismatch")
                    ? .fileDigestMismatch : .fileDownloadFailed
                throw ResolverFailure(reason: reason, description: detail)
            }
        }
        try manifestData.write(
            to: staging.appendingPathComponent(SpecDecStore.manifestFileName),
            options: [.atomic])
        switch SpecDecStore.verifyPublishedArtifact(at: staging, reference: reference) {
        case .success(let verification): return verification
        case .failure(let error):
            throw ResolverFailure(reason: error.reason, description: error.description)
        }
    }

    private func fetchManifest(
        reference: SpecDecArtifactReference
    ) async throws -> (ModelManifest, Data) {
        let urlString = "\(downloader.r2CDNURL)/\(ModelDownloader.escapeR2Path(reference.r2Prefix))/manifest.json"
        guard let url = URL(string: urlString) else {
            throw ResolverFailure(reason: .manifestFetchFailed, description: "invalid manifest URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await downloader.urlSession.bytes(for: request)
        } catch {
            throw ResolverFailure(reason: .manifestFetchFailed, description: "manifest request failed")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResolverFailure(reason: .manifestFetchFailed, description: "manifest returned a non-success status")
        }
        if response.expectedContentLength > Int64(SpecDecLimits.maximumManifestBytes) {
            throw ResolverFailure(reason: .manifestMalformed, description: "manifest exceeds byte bound")
        }
        var data = Data()
        data.reserveCapacity(min(
            max(0, Int(response.expectedContentLength)), SpecDecLimits.maximumManifestBytes))
        do {
            for try await byte in bytes {
                guard data.count < SpecDecLimits.maximumManifestBytes else {
                    throw ResolverFailure(reason: .manifestMalformed, description: "manifest exceeds byte bound")
                }
                data.append(byte)
            }
        } catch let failure as ResolverFailure {
            throw failure
        } catch {
            throw ResolverFailure(reason: .manifestFetchFailed, description: "manifest stream failed")
        }
        do {
            return (
                try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data),
                data)
        } catch {
            throw ResolverFailure(reason: .manifestMalformed, description: "manifest JSON decode failed")
        }
    }

    private func artifact(
        from verification: SpecDecStore.Verification,
        directory: URL,
        reference: SpecDecArtifactReference
    ) -> SpecDecArtifact {
        SpecDecArtifact(
            directory: directory,
            source: .catalog,
            revision: reference.revision,
            artifactBytes: verification.artifactBytes,
            residentBytes: SpecDecLimits.residentEstimate(
                artifactBytes: verification.artifactBytes),
            manifestSHA256: verification.manifestSHA256,
            catalogReference: reference)
    }

    private struct ResolverFailure: Error, Sendable, CustomStringConvertible {
        let reason: MTPFallbackReason
        let description: String
    }
}
