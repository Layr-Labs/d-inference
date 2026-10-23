// Copyright © 2026 Eigen Labs.
import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// Committed fixtures from `scripts/nemotron-qualification/image-goldens`.
/// Read through the source tree so the isolated harness needs no resource bundle.
enum NemotronSuperImageFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/NemotronSuperImages", isDirectory: true)

    static func data(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }

    struct Case: Decodable {
        let name: String
        let file: String
        let format: String
        let width: Int
        let height: Int
        let unorientedWidth: Int
        let unorientedHeight: Int
        let rgbSha256: String
        let unorientedRgbSha256: String
        let pillowRgb: String?
        let chroma: String?
    }
    struct Tensor: Decodable {
        let name: String
        let width: Int
        let height: Int
        let tokens: Int
        let count: Int
        let indices: [Int]
        let values: [Double]
        let sum: Double
        let sumSquares: Double
    }
    private struct Reference: Decodable { let pillow: String; let cases: [Case] }
    private struct Tensors: Decodable { let torch: String; let tensors: [Tensor] }

    static func cases() throws -> [Case] {
        let reference = try decoder.decode(Reference.self, from: data("reference.json"))
        #expect(reference.pillow == "12.2.0")
        return reference.cases
    }

    static func tensors() throws -> [String: Tensor] {
        let tensors = try decoder.decode(Tensors.self, from: data("tensors.json"))
        #expect(tensors.torch == "2.12.0")
        return Dictionary(uniqueKeysWithValues: tensors.tensors.map { ($0.name, $0) })
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Parity with the reference loader (transformers `load_image`: Pillow 12.2.0
/// `exif_transpose` + `convert("RGB")`) and with NVIDIA's processor tensors
/// (CPU PyTorch 2.12.0 antialiased bicubic + normalization).
struct NemotronSuperImageGoldenTests {
    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Inclusive bounds on |ImageIO - Pillow| per RGB8 sample, set about a third
    /// above the values measured on these fixtures (macOS 27.2, Apple silicon).
    /// Full-resolution chroma differs only by IDCT rounding (measured max 3);
    /// gray and CMYK carry no chroma (max 1); 4:2:2 measured max 3. With 2x2
    /// chroma ImageIO replicates chroma at 16-pixel MCU edges where libjpeg-turbo
    /// interpolates across them: smooth content measured max 9, saturated colour
    /// edges max 46, while samples off MCU edges stay within the IDCT bound.
    private func jpegBound(_ chroma: String?) -> (maximum: Int, mean: Double, interior: Int?) {
        switch chroma {
        case "gray", "cmyk": return (2, 0.1, nil)
        case "444": return (4, 0.5, nil)
        case "422": return (5, 0.6, nil)
        case "420": return (12, 0.75, 4)
        case "420-edges": return (64, 0.75, 4)
        default: return (0, 0, nil)
        }
    }

    @Test func losslessFormatsMatchPillowBytesExactly() throws {
        let cases = try NemotronSuperImageFixtures.cases().filter { $0.format == "png" }
        #expect(cases.count >= 50)
        for fixture in cases {
            let data = try NemotronSuperImageFixtures.data(fixture.file)
            let quote = try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
            #expect(quote.format == .png, "\(fixture.name)")
            #expect(quote.width == fixture.width && quote.height == fixture.height, "\(fixture.name)")
            let oriented = try NemotronSuperImageDecode.decode(data, orientation: .applyEXIF)
            #expect(oriented.width == fixture.width && oriented.height == fixture.height, "\(fixture.name)")
            #expect(sha256(oriented.rgb) == fixture.rgbSha256, "\(fixture.name)")
            let raster = try NemotronSuperImageDecode.decode(data, orientation: .preserveRaster)
            #expect(raster.width == fixture.unorientedWidth && raster.height == fixture.unorientedHeight)
            #expect(sha256(raster.rgb) == fixture.unorientedRgbSha256, "\(fixture.name)")
        }
    }

    @Test func jpegSamplesStayWithinImageIOBounds() throws {
        let cases = try NemotronSuperImageFixtures.cases().filter { $0.format == "jpeg" }
        #expect(cases.count >= 30)
        for fixture in cases {
            let data = try NemotronSuperImageFixtures.data(fixture.file)
            let quote = try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
            #expect(quote.format == .jpeg, "\(fixture.name)")
            let decoded = try NemotronSuperImageDecode.decode(data, orientation: .applyEXIF)
            #expect(decoded.width == fixture.width && decoded.height == fixture.height, "\(fixture.name)")
            let packed = try NemotronSuperImageFixtures.data(try #require(fixture.pillowRgb))
            let pillow = [UInt8](try (packed as NSData).decompressed(using: .zlib) as Data)
            try #require(pillow.count == decoded.rgb.count, "\(fixture.name)")
            let bound = jpegBound(fixture.chroma)
            var maximum = 0, total = 0, interior = 0
            for index in 0..<pillow.count {
                let error = abs(Int(pillow[index]) - Int(decoded.rgb[index]))
                maximum = max(maximum, error)
                total += error
                let pixel = index / 3, x = pixel % decoded.width, y = pixel / decoded.width
                if ![0, 15].contains(x % 16), ![0, 15].contains(y % 16) { interior = max(interior, error) }
            }
            let mean = Double(total) / Double(pillow.count)
            #expect(maximum <= bound.maximum && mean <= bound.mean,
                    "\(fixture.name): max \(maximum), mean \(mean)")
            if let limit = bound.interior { #expect(interior <= limit, "\(fixture.name): interior \(interior)") }
            let raster = try NemotronSuperImageDecode.decode(data, orientation: .preserveRaster)
            #expect(raster.width == fixture.unorientedWidth && raster.height == fixture.unorientedHeight)
        }
    }

    /// Lossless inputs are bitwise equal to the reference tensors at every
    /// sampled index. JPEG tensors may differ by the decoded-sample error times
    /// the resize kernel's L1 gain (at most 1.2 per axis for Keys a=-0.5)
    /// divided by 255 and the smallest channel std.
    @Test func normalizedTensorsMatchReferenceProcessor() throws {
        let tensors = try NemotronSuperImageFixtures.tensors()
        for fixture in try NemotronSuperImageFixtures.cases() {
            let reference = try #require(tensors[fixture.name])
            let data = try NemotronSuperImageFixtures.data(fixture.file)
            let prepared = try NemotronSuperImageDecode.prepare(data, orientation: .applyEXIF)
            #expect(prepared.grid.width == reference.width && prepared.grid.height == reference.height
                    && prepared.grid.tokens == reference.tokens, "\(fixture.name)")
            try #require(prepared.normalizedCHW.count == reference.count, "\(fixture.name)")
            let tolerance: Float = fixture.format == "png"
                ? 0 : Float(jpegBound(fixture.chroma).maximum) * 1.44 / (255 * 0.26130258)
            for (index, value) in zip(reference.indices, reference.values) {
                #expect(abs(prepared.normalizedCHW[index] - Float(value)) <= tolerance,
                        "\(fixture.name)[\(index)]")
            }
            if fixture.format == "png" {
                var sum = 0.0, squares = 0.0
                for value in prepared.normalizedCHW {
                    sum += Double(value)
                    squares += Double(value) * Double(value)
                }
                // Same float32 values; only the reference's summation order differs.
                #expect(abs(sum - reference.sum) <= 1e-9 * max(1, abs(reference.sum)), "\(fixture.name)")
                #expect(abs(squares - reference.sumSquares) <= 1e-9 * reference.sumSquares, "\(fixture.name)")
            }
        }
    }
}
