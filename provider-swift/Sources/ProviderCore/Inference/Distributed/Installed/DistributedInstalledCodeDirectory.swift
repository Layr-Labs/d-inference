import CryptoKit
import Foundation

/// The code-directory hashes (cdhashes) the kernel can give an arm64 image of
/// an installed executable, read from the bytes `DistributedInstalledFiles`
/// hashes against the pin as they stream past (the file is never read again).
///
/// Thin Mach-O, or every arm64/arm64e slice of a fat file: `LC_CODE_SIGNATURE`,
/// its SuperBlob, and the CodeDirectory at slot 0 or an alternate slot whose
/// hash type the kernel ranks highest (SHA-384, SHA-256, truncated SHA-256,
/// SHA-1; the first wins a tie). The cdhash is that hash of the CodeDirectory
/// blob, truncated to 20 bytes. Anything unsigned, malformed or out of order
/// yields no hash, so it can never be launched as verified.
struct DistributedInstalledCodeDirectory {
    static let hashBytes = 20
    private static let maximumSlices = 32
    private static let maximumCommandBytes = 4 << 20
    private static let maximumSignatureBytes = 32 << 20
    private static let maximumBlobs = 64

    private enum Part {
        case magic
        case architectures(count: Int, wide: Bool)
        case header(slice: Int, size: Int)
        case commands(slice: Int, size: Int, count: Int)
        case signature
    }
    private struct Wanted { let start: Int; let length: Int; let part: Part; var bytes = Data() }

    /// The file's first bytes are kept, so a part that starts in them (the
    /// headers) can be named after the stream has passed it.
    private static let prefixBytes = 64 << 10
    private let fileSize: Int
    private var position = 0
    private var prefix = Data()
    private var wanted: [Wanted] = []
    private var buffered = 0
    private var failed = false
    private var found: Set<Data> = []

    init(fileSize: Int) {
        self.fileSize = fileSize
        want(0, 8, .magic)
    }

    /// The cdhashes of every arm64 slice, or none when any part is missing or invalid.
    func finish() -> Set<Data> {
        failed || !wanted.isEmpty || position != fileSize ? [] : found
    }

    mutating func update(_ chunk: Data) {
        let base = position, end = base + chunk.count
        defer { position = end }
        guard !failed, !chunk.isEmpty else { return }
        if prefix.count == base, base < Self.prefixBytes { prefix.append(chunk.prefix(Self.prefixBytes - base)) }
        var index = 0
        while index < wanted.count, !failed {
            let next = wanted[index].start + wanted[index].bytes.count
            let last = wanted[index].start + wanted[index].length
            guard next >= base else { failed = true; break }
            if next < end, next < last {
                wanted[index].bytes.append(chunk[chunk.startIndex + (next - base) ..< chunk.startIndex + (min(last, end) - base)])
            }
            if wanted[index].bytes.count == wanted[index].length {
                let done = wanted.remove(at: index)
                buffered -= done.length
                accept(done)
                // A part this one names may start inside this chunk: look again from the first.
                index = 0
            } else {
                index += 1
            }
        }
    }

    private mutating func want(_ start: Int, _ length: Int, _ part: Part) {
        guard start >= 0, length > 0, start <= fileSize - length,
              buffered <= Self.maximumSignatureBytes + Self.maximumCommandBytes - length else { failed = true; return }
        var item = Wanted(start: start, length: length, part: part)
        if start < prefix.count { item.bytes = prefix.subdata(in: start ..< min(prefix.count, start + length)) }
        // Bytes that already went past and are not in the prefix cannot be read again.
        guard start + item.bytes.count >= position else { failed = true; return }
        wanted.append(item); buffered += length
    }

    private mutating func accept(_ done: Wanted) {
        let bytes = done.bytes
        switch done.part {
        case .magic:
            let fat = Self.big(bytes, 0)
            if fat == 0xcafe_babe || fat == 0xcafe_babf {
                let count = Int(Self.big(bytes, 4)), wide = fat == 0xcafe_babf
                guard (1...Self.maximumSlices).contains(count) else { failed = true; return }
                want(8, count * (wide ? 32 : 20), .architectures(count: count, wide: wide))
            } else {
                want(0, 32, .header(slice: 0, size: fileSize))
            }
        case .architectures(let count, let wide):
            var slices: [(offset: Int, size: Int)] = []
            for entry in 0..<count {
                let at = entry * (wide ? 32 : 20)
                let cpu = Self.big(bytes, at)
                let offset = wide ? Self.big64(bytes, at + 8) : UInt64(Self.big(bytes, at + 8))
                let size = wide ? Self.big64(bytes, at + 16) : UInt64(Self.big(bytes, at + 12))
                guard offset <= UInt64(fileSize), size <= UInt64(fileSize) - offset, size >= 32 else { failed = true; return }
                if cpu == Self.arm64 { slices.append((Int(offset), Int(size))) }
            }
            guard !slices.isEmpty else { failed = true; return }
            for slice in slices.sorted(by: { $0.offset < $1.offset }) {
                want(slice.offset, 32, .header(slice: slice.offset, size: slice.size))
            }
        case .header(let slice, let size):
            let commands = Int(Self.little(bytes, 20))
            guard Self.little(bytes, 0) == 0xfeed_facf, Self.little(bytes, 4) == Self.arm64,
                  (1...Self.maximumCommandBytes).contains(commands), commands <= size - 32 else { failed = true; return }
            want(slice + 32, commands, .commands(slice: slice, size: size, count: Int(Self.little(bytes, 16))))
        case .commands(let slice, let size, let count):
            var at = 0, signature: (offset: Int, size: Int)?
            for _ in 0..<count {
                guard at <= bytes.count - 8 else { failed = true; return }
                let command = Self.little(bytes, at), length = Int(Self.little(bytes, at + 4))
                guard length >= 8, length <= bytes.count - at else { failed = true; return }
                if command == 0x1d {
                    guard signature == nil, length >= 16 else { failed = true; return }
                    signature = (Int(Self.little(bytes, at + 8)), Int(Self.little(bytes, at + 12)))
                }
                at += length
            }
            guard let signature, signature.offset >= 32 + bytes.count,
                  (12...Self.maximumSignatureBytes).contains(signature.size),
                  signature.offset <= size - signature.size else { failed = true; return }
            want(slice + signature.offset, signature.size, .signature)
        case .signature:
            guard let hash = Self.codeDirectoryHash(bytes) else { failed = true; return }
            found.insert(hash)
        }
    }

    /// The kernel's choice among the CodeDirectories of one embedded signature, hashed.
    private static func codeDirectoryHash(_ blob: Data) -> Data? {
        guard big(blob, 0) == 0xfade_0cc0 else { return nil }
        let length = Int(big(blob, 4)), count = Int(big(blob, 8))
        guard length <= blob.count, length >= 12, (1...maximumBlobs).contains(count), 12 + count * 8 <= length else { return nil }
        var best: (rank: Int, type: UInt8, directory: Data)?
        for entry in 0..<count {
            let slot = big(blob, 12 + entry * 8), offset = Int(big(blob, 16 + entry * 8))
            guard slot == 0 || (0x1000..<0x1005).contains(slot) else { continue }
            guard offset >= 12 + count * 8, offset <= length - 44, big(blob, offset) == 0xfade_0c02 else { return nil }
            let size = Int(big(blob, offset + 4))
            guard size >= 44, size <= length - offset else { return nil }
            let type = blob[blob.startIndex + offset + 37]
            let rank = [1: 1, 3: 2, 2: 3, 4: 4][type] ?? 0
            if rank > (best?.rank ?? 0) {
                best = (rank, type, blob.subdata(in: blob.startIndex + offset ..< blob.startIndex + offset + size))
            }
        }
        guard let best else { return nil }
        let digest: Data
        switch best.type {
        case 1: digest = Data(Insecure.SHA1.hash(data: best.directory))
        case 4: digest = Data(SHA384.hash(data: best.directory))
        default: digest = Data(SHA256.hash(data: best.directory))
        }
        return digest.prefix(hashBytes)
    }

    private static let arm64: UInt32 = 0x0100_000c
    private static func big(_ data: Data, _ at: Int) -> UInt32 {
        data[data.startIndex + at ..< data.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func big64(_ data: Data, _ at: Int) -> UInt64 { UInt64(big(data, at)) << 32 | UInt64(big(data, at + 4)) }
    private static func little(_ data: Data, _ at: Int) -> UInt32 { big(data, at).byteSwapped }
}
