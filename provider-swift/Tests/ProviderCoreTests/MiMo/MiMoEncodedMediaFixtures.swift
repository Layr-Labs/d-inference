@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Locally generated, bounded fixtures. No network, user media, or external codec
/// executable is needed. The temporary encoded movie is removed before returning.
enum MiMoEncodedMediaFixtures {
    static func image(jpeg: Bool, width: Int = 64, height: Int = 48) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            pixels[i * 4] = UInt8(i % 251)
            pixels[i * 4 + 1] = UInt8((i / width) % 251)
            pixels[i * 4 + 2] = 173
            pixels[i * 4 + 3] = jpeg ? 255 : UInt8(i % 256)
        }
        let image = try XCTUnwrap(CGImage(width:width, height:height, bitsPerComponent:8,
            bitsPerPixel:32, bytesPerRow:width * 4, space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData)),
            decode:nil, shouldInterpolate:false, intent:.defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,
            (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func video(frames: Int, fps: Int32, width: Int = 64, height: Int = 48) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL:url, fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video, outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264, AVVideoWidthKey:width, AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:true,
                AVVideoMaxKeyFrameIntervalKey:30],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,
            sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:width, kCVPixelBufferHeightKey as String:height])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime:.zero)
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for:.milliseconds(1))
            }
            try autoreleasepool {
                var value: CVPixelBuffer?
                let pool = try XCTUnwrap(adaptor.pixelBufferPool)
                XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &value), kCVReturnSuccess)
                let pixel = try XCTUnwrap(value)
                XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
                let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to:UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * stride + x * 4
                        pointer[offset] = UInt8(index % 251)
                        pointer[offset + 1] = UInt8(y % 251)
                        pointer[offset + 2] = UInt8(x % 251)
                        pointer[offset + 3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                guard adaptor.append(pixel, withPresentationTime:CMTime(value:Int64(index), timescale:fps)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf:url)
    }
}
