// Copyright © 2026 Eigen Labs.
import Foundation

/// Pillow 12.2 `chunk_tEXt`, `chunk_zTXt`, `chunk_iTXt` and `chunk_iCCP`,
/// reduced to what can refuse a file or change orientation. Pillow refuses a
/// compressed chunk that inflates to `MAX_TEXT_CHUNK` (1 MiB) with input left
/// over, and text totalling more than `MAX_TEXT_MEMORY` (64 MiB, counted in
/// decoded characters). Both are applied to every chunk here, including chunks
/// after a later APNG frame that Pillow would not read for frame 0. Only the
/// EXIF/XMP keys can change pixels; values stored under them with a different
/// type are refused.
struct NemotronSuperPNGText {
    enum Entry { case ignored, rawProfile, xmp(Data) }

    static let maximumChunkBytes = 1024 * 1024
    static let maximumTotalCharacters = 64 * maximumChunkBytes
    private var characters = 0

    private typealias Failure = NemotronSuperImageDecode.Failure
    private static let xmpKeyword = "XML:com.adobe.xmp"
    private static let rawProfileKeyword = "Raw profile type exif"

    mutating func read(_ type: NemotronSuperPNGContainer.ChunkType,
                       _ bytes: UnsafeRawBufferPointer) throws -> Entry {
        let separator = bytes.firstIndex(of: 0)
        let keywordBytes = bytes[..<(separator ?? bytes.count)]
        let keyword = String(decoding: keywordBytes, as: UTF8.self)
        let value = separator.map { $0 + 1 } ?? bytes.count
        guard keyword != "exif", keyword != "xmp" else { throw Failure.unsupportedEncoding }
        switch type {
        case .text:
            guard !keywordBytes.isEmpty else { return .ignored }
            try count(bytes.count - value)
            return entry(keyword, Data(bytes[value...]))
        case .compressedText:
            // Pillow raises for a non-zlib method whatever the keyword.
            guard value >= bytes.count || bytes[value] == 0 else { throw Failure.invalidHeader }
            let stream = Self.slice(bytes, from: value + 1)
            var text = Data()
            // An empty stream is empty text in Pillow, not a zlib error.
            if !stream.isEmpty {
                switch NemotronSuperInflater.pillowDecompress(stream, limit: Self.maximumChunkBytes) {
                case .tooLarge: throw Failure.sizeLimit
                case .corrupt:
                    // Pillow stores empty text; an orientation source must decode.
                    guard keyword != Self.xmpKeyword else { throw Failure.invalidHeader }
                case .output(let output, let complete):
                    guard complete || keyword != Self.xmpKeyword else { throw Failure.invalidHeader }
                    text = output
                }
            }
            guard !keywordBytes.isEmpty else { return .ignored }
            try count(text.count)
            return entry(keyword, text)
        default:
            return try readInternational(keyword: keyword, bytes: bytes, value: value)
        }
    }

    /// iTXt: keyword, compression flag and method, language, translated
    /// keyword, text. Pillow ignores malformed, non-zlib, undecodable and
    /// invalid UTF-8 forms; for XMP those forms are refused instead.
    private mutating func readInternational(keyword: String, bytes: UnsafeRawBufferPointer,
                                            value: Int) throws -> Entry {
        let isXMP = keyword == Self.xmpKeyword
        func ignored() throws -> Entry {
            guard !isXMP else { throw Failure.unsupportedEncoding }
            return .ignored
        }
        guard value <= bytes.count - 2,
              let language = bytes[(value + 2)...].firstIndex(of: 0),
              let translated = bytes[(language + 1)...].firstIndex(of: 0) else { return try ignored() }
        let compressed = bytes[value] != 0
        let stream = Self.slice(bytes, from: translated + 1)
        var text = Data(stream)
        if compressed {
            guard bytes[value + 1] == 0 else { return try ignored() }
            switch NemotronSuperInflater.pillowDecompress(stream, limit: Self.maximumChunkBytes) {
            case .tooLarge: throw Failure.sizeLimit
            case .corrupt: return try ignored()
            case .output(let output, let complete):
                guard complete || !isXMP else { throw Failure.invalidHeader }
                text = output
            }
        }
        // Pillow keeps an XMP packet whose text is not UTF-8, but neither counts nor stores it as text.
        guard Self.scalarCount(bytes[(value + 2)..<language]) != nil,
              Self.scalarCount(bytes[(language + 1)..<translated]) != nil,
              let characters = Self.scalarCount(text) else { return isXMP ? .xmp(text) : .ignored }
        try count(characters)
        return entry(keyword, text)
    }

    /// Code points of strictly valid UTF-8 (Python's `len(bytes.decode("utf-8"))`).
    /// Decoding replaces every ill-formed sequence, so a lossless round trip
    /// means the input was valid.
    private static func scalarCount(_ bytes: some Collection<UInt8>) -> Int? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        guard decoded.utf8.elementsEqual(bytes) else { return nil }
        return decoded.unicodeScalars.count
    }

    /// iCCP: Pillow requires a zlib method and refuses a profile that
    /// inflates past `MAX_TEXT_CHUNK`; a corrupt stream is ignored.
    static func checkProfile(_ bytes: UnsafeRawBufferPointer) throws {
        guard let name = bytes.prefix(81).firstIndex(of: 0), name > 0, name + 1 < bytes.count,
              bytes[name + 1] == 0 else { throw Failure.invalidHeader }
        if case .tooLarge = NemotronSuperInflater.pillowDecompress(slice(bytes, from: name + 2),
                                                                    limit: maximumChunkBytes) {
            throw Failure.sizeLimit
        }
    }

    private mutating func count(_ value: Int) throws {
        characters += value
        guard characters <= Self.maximumTotalCharacters else { throw Failure.sizeLimit }
    }

    private func entry(_ keyword: String, _ text: Data) -> Entry {
        switch keyword {
        case Self.xmpKeyword: return .xmp(text)
        case Self.rawProfileKeyword: return .rawProfile
        default: return .ignored
        }
    }

    private static func slice(_ bytes: UnsafeRawBufferPointer, from start: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: bytes[min(start, bytes.count)...])
    }
}
