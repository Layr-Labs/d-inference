// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import Foundation

/// An `AVURLAsset` whose bytes are served from memory, for the Super video
/// reader. The SDK's `MemoryBackedVideoAsset` validates the same bytes in
/// `MediaIngest.decodeVideo` but keeps its asset package-private, so the
/// reader owns this copy. It keeps the asset, loader, bytes and delegate
/// queue alive together (the resource loader holds its delegate weakly); the
/// custom URL is never backed by a file or network resource.
final class NemotronSuperVideoAsset: @unchecked Sendable {
    private let asset: AVURLAsset
    private let loader: NemotronSuperVideoResourceLoader
    private let queue: DispatchQueue

    var byteCount: Int { loader.data.count }

    /// `data` must already have passed `MemoryBackedVideoAsset`'s container
    /// check; its major brand chooses the QuickTime or MP4 type hint.
    init(videoData data: Data) throws {
        guard !data.isEmpty else { throw NemotronSuperVideoDecode.Failure.invalidVideo }
        let quickTime = data.count >= 12 && data[data.startIndex + 4 ..< data.startIndex + 12]
            .elementsEqual(Array("ftypqt  ".utf8))
        let token = UUID().uuidString.lowercased()
        guard let url = URL(string: "darkbloom-super-video://\(token)/asset.\(quickTime ? "mov" : "mp4")") else {
            throw NemotronSuperVideoDecode.Failure.invalidVideo
        }
        loader = NemotronSuperVideoResourceLoader(data: data, url: url,
            contentType: quickTime ? AVFileType.mov.rawValue : AVFileType.mp4.rawValue)
        queue = DispatchQueue(label: "ai.darkbloom.super-video.\(token)", qos: .userInitiated)
        asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        asset.resourceLoader.setDelegate(loader, queue: queue)
    }

    /// Runs `operation` while this owner, and so the loader and bytes, stay alive.
    func withAsset<Result>(_ operation: (AVURLAsset) async throws -> Result) async rethrows -> Result {
        defer { withExtendedLifetime(self) {} }
        return try await operation(asset)
    }

    /// The asset for a reader that retains this owner for its whole lifetime.
    var retainedAsset: AVURLAsset { asset }
}

private final class NemotronSuperVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate,
    @unchecked Sendable {
    let data: Data
    private let url: URL
    private let contentType: String

    init(data: Data, url: URL, contentType: String) {
        self.data = data
        self.url = url
        self.contentType = contentType
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url == url else {
            loadingRequest.finishLoading(with: NemotronSuperVideoDecode.Failure.invalidVideo)
            return true
        }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        guard let request = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        // A request past the end is clamped to it; a negative, overflowing or
        // wholly out-of-resource range fails the load.
        let length = Int64(data.count)
        let start = max(request.requestedOffset, request.currentOffset)
        let (requestedEnd, overflow) = request.requestedOffset.addingReportingOverflow(Int64(request.requestedLength))
        let end = request.requestsAllDataToEndOfResource ? length : min(requestedEnd, length)
        guard request.requestedOffset >= 0, request.requestedLength >= 0, start >= 0, start <= length,
            request.requestsAllDataToEndOfResource || (!overflow && requestedEnd >= start)
        else {
            loadingRequest.finishLoading(with: NemotronSuperVideoDecode.Failure.invalidVideo)
            return true
        }
        if start < end {
            let lower = data.index(data.startIndex, offsetBy: Int(start))
            let upper = data.index(data.startIndex, offsetBy: Int(end))
            request.respond(with: data[lower ..< upper])
        }
        loadingRequest.finishLoading()
        return true
    }
}
