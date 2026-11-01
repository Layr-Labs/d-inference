// Copyright © 2026 Eigen Labs.
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing

/// Small movies written with AVAssetWriter for the Super video tests, and
/// byte edits of them. No network, user media or external codec tool; the
/// temporary files are removed before returning.
enum NemotronSuperVideoClips {
    /// `frames` frames at `fps`, each frame and position distinct, without
    /// frame reordering. `durations` (in 1/`fps` units) repeat over the
    /// frames; AVAssetWriter gives the last frame its predecessor's duration.
    static func movie(frames: Int, fps: Int32, width: Int = 64, height: Int = 64, fileType: AVFileType = .mp4,
                      codec: AVVideoCodecType = .h264, durations: [Int64] = [1]) async throws -> Data {
        let url = temporaryURL(fileType)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if codec == .h264 { settings[AVVideoCompressionPropertiesKey] = [AVVideoAllowFrameReorderingKey: false] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var time: Int64 = 0
        for index in 0 ..< frames {
            try await waitUntilReady(input, writer)
            let pixel = try frame(index, width: width, height: height, pool: try #require(adaptor.pixelBufferPool))
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: time, timescale: fps)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            time += durations[index % durations.count]
        }
        return try await finish(writer, [input], url: url)
    }

    /// One movie with two video tracks carrying the same samples.
    static func twoTracks(frames: Int, fps: Int32) async throws -> Data {
        let samples = try await compressedSamples(try await movie(frames: frames, fps: fps))
        let url = temporaryURL(.mp4)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let hint = CMSampleBufferGetFormatDescription(try #require(samples.first))
        let inputs = (0 ..< 2).map { _ in
            AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        }
        for input in inputs { writer.add(input) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for sample in samples {
            for input in inputs {
                try await waitUntilReady(input, writer)
                guard input.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
        }
        return try await finish(writer, inputs, url: url)
    }

    /// `movie` (one track, its `moov` after `mdat`) with the duration of its
    /// last `stts` run set to zero. That run covers at least the last two
    /// frames, so a frame before the last has zero duration.
    static func zeroingLastDurationRun(_ movie: Data) throws -> Data {
        var data = movie
        let type = try #require(data.range(of: Data("stts".utf8), options: .backwards))
        let box = type.lowerBound - 4
        let entries = Int(integer(data, at: box + 12))
        try #require(entries > 0)
        let delta = box + 16 + (entries - 1) * 8 + 4
        data.replaceSubrange(delta ..< delta + 4, with: [0, 0, 0, 0])
        return data
    }

    /// `movie` with its leading `ftyp` atom renamed `free`: a legacy
    /// QuickTime layout, whose chunk offsets stay valid.
    static func withoutFileType(_ movie: Data) throws -> Data {
        try #require(movie.count > 8 && movie[movie.startIndex + 4 ..< movie.startIndex + 8] == Data("ftyp".utf8))
        var data = movie
        data.replaceSubrange(data.startIndex + 4 ..< data.startIndex + 8, with: Data("free".utf8))
        return data
    }

    static func uri(_ movie: Data, quickTime: Bool = false) -> String {
        "data:video/\(quickTime ? "quicktime" : "mp4");base64," + movie.base64EncodedString()
    }

    private static func temporaryURL(_ fileType: AVFileType) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + (fileType == .mov ? ".mov" : ".mp4"))
    }

    private static func integer(_ data: Data, at offset: Int) -> UInt32 {
        data[data.startIndex + offset ..< data.startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func finish(_ writer: AVAssetWriter, _ inputs: [AVAssetWriterInput], url: URL) async throws -> Data {
        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: url)
    }

    /// BGRA whose channels vary with the frame index and position.
    private static func frame(_ index: Int, width: Int, height: Int, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        try #require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &value) == kCVReturnSuccess)
        let pixel = try #require(value)
        try #require(CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let pointer = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * stride + x * 4
                pointer[offset] = UInt8((x * 7 + index * 53) & 255)
                pointer[offset + 1] = UInt8((y * 5 + index * 29) & 255)
                pointer[offset + 2] = UInt8(((x ^ y) * 3 + index * 11) & 255)
                pointer[offset + 3] = 255
            }
        }
        return pixel
    }

    /// The compressed samples of `movie`'s video track, in decode order.
    private static func compressedSamples(_ movie: Data) async throws -> [CMSampleBuffer] {
        let url = temporaryURL(.mp4)
        defer { try? FileManager.default.removeItem(at: url) }
        try movie.write(to: url)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { samples.append(sample) }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return samples
    }
}
