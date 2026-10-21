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
    /// The QuickTime or MP4 type hint, by `contentType(of:)`.
    let contentType: AVFileType

    /// `data` must already have passed `MemoryBackedVideoAsset`'s container
    /// check; the same rule (`contentType(of:)`) chooses its type hint.
    init(videoData data: Data) throws {
        let contentType = try Self.contentType(of: data)
        let token = UUID().uuidString.lowercased()
        guard let url = URL(string: "darkbloom-super-video://\(token)/asset.\(contentType == .mov ? "mov" : "mp4")")
        else { throw NemotronSuperVideoDecode.Failure.invalidVideo }
        self.contentType = contentType
        loader = NemotronSuperVideoResourceLoader(data: data, url: url, contentType: contentType.rawValue)
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

    /// The container rule of the SDK's `MemoryBackedVideoAsset`, which keeps
    /// it package-private: the top-level atoms must tile the data; an `ftyp`
    /// atom anywhere among them gives QuickTime for major brand `qt  ` and MP4
    /// for any other, and without one a legacy QuickTime movie holds `moov`
    /// and `mdat`.
    static func contentType(of data: Data) throws -> AVFileType {
        func integer(at offset: Int, bytes: Int) -> UInt64? {
            guard offset >= 0, bytes <= data.count - offset else { return nil }
            let start = data.startIndex + offset
            return data[start ..< start + bytes].reduce(0) { $0 << 8 | UInt64($1) }
        }
        // Big-endian four-character codes.
        let ftyp: UInt64 = 0x6674_7970, moov: UInt64 = 0x6D6F_6F76, mdat: UInt64 = 0x6D64_6174
        let quickTimeBrand: UInt64 = 0x7174_2020
        let invalid = NemotronSuperVideoDecode.Failure.invalidVideo
        var offset = 0
        var brand: UInt64?
        var sawMovie = false, sawMedia = false
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8, let size = integer(at: offset, bytes: 4), let type = integer(at: offset + 4, bytes: 4)
            else { throw invalid }
            let header = size == 1 ? 16 : 8
            let atom: Int
            switch size {
            case 0: atom = remaining
            case 1:
                guard let extended = integer(at: offset + 8, bytes: 8), extended >= 16, extended <= UInt64(remaining)
                else { throw invalid }
                atom = Int(extended)
            default:
                guard size >= 8, size <= UInt64(remaining) else { throw invalid }
                atom = Int(size)
            }
            switch type {
            case ftyp:
                guard brand == nil, size != 0, atom >= header + 8, let major = integer(at: offset + header, bytes: 4)
                else { throw invalid }
                brand = major
            case moov: sawMovie = true
            case mdat: sawMedia = true
            default: break
            }
            offset += atom
        }
        if let brand { return brand == quickTimeBrand ? .mov : .mp4 }
        guard sawMovie, sawMedia else { throw invalid }
        return .mov
    }
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
