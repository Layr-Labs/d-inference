import CryptoKit
import Darwin
import Foundation

enum AuditError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

struct TensorLocation: Sendable {
    let name: String
    let dtype: String
    let shape: [Int]
    let shardURL: URL
    let payloadOffset: Int64
    let byteCount: Int

    var elementCount: Int {
        shape.reduce(1, *)
    }
}

struct ShardRecord: Sendable {
    let url: URL
    let headerLength: Int
    let tensorCount: Int
    let fileSize: Int64
}

struct SafeTensorIndex: Sendable {
    let tensors: [String: TensorLocation]
    let shards: [ShardRecord]

    init(snapshotURL: URL) throws {
        let shardURLs = try FileManager.default.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !shardURLs.isEmpty else {
            throw AuditError.invalid("snapshot contains no .safetensors shards")
        }

        var allTensors: [String: TensorLocation] = [:]
        var shardRecords: [ShardRecord] = []
        for shardURL in shardURLs {
            let handle = try FileHandle(forReadingFrom: shardURL)
            defer { try? handle.close() }

            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
                throw AuditError.invalid("\(shardURL.path): truncated safetensors prefix")
            }
            let headerLength = prefix.withUnsafeBytes { raw -> UInt64 in
                var value: UInt64 = 0
                for byteIndex in 0..<8 {
                    value |= UInt64(raw[byteIndex]) << UInt64(byteIndex * 8)
                }
                return value
            }
            guard headerLength <= UInt64(Int.max) else {
                throw AuditError.invalid("\(shardURL.path): header is too large")
            }
            guard
                let headerData = try handle.read(upToCount: Int(headerLength)),
                headerData.count == Int(headerLength)
            else {
                throw AuditError.invalid("\(shardURL.path): truncated safetensors header")
            }
            guard
                let object = try JSONSerialization.jsonObject(with: headerData)
                    as? [String: Any]
            else {
                throw AuditError.invalid("\(shardURL.path): safetensors header is not an object")
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: shardURL.path)
            guard let fileSizeNumber = attributes[.size] as? NSNumber else {
                throw AuditError.invalid("\(shardURL.path): cannot read file size")
            }
            let fileSize = fileSizeNumber.int64Value
            let payloadBase = Int64(8) + Int64(headerLength)
            var shardTensorCount = 0

            for (name, rawMetadata) in object where name != "__metadata__" {
                guard
                    let metadata = rawMetadata as? [String: Any],
                    let dtype = metadata["dtype"] as? String,
                    let rawShape = metadata["shape"] as? [NSNumber],
                    let rawOffsets = metadata["data_offsets"] as? [NSNumber],
                    rawOffsets.count == 2
                else {
                    throw AuditError.invalid(
                        "\(shardURL.lastPathComponent): malformed metadata for \(name)"
                    )
                }
                let shape = rawShape.map(\.intValue)
                guard shape.allSatisfy({ $0 >= 0 }) else {
                    throw AuditError.invalid("\(name): negative tensor dimension")
                }
                let begin = rawOffsets[0].int64Value
                let end = rawOffsets[1].int64Value
                guard begin >= 0, end >= begin, payloadBase + end <= fileSize else {
                    throw AuditError.invalid("\(name): tensor offsets are outside its shard")
                }
                guard end - begin <= Int64(Int.max) else {
                    throw AuditError.invalid("\(name): tensor byte span is too large")
                }
                let byteCount = Int(end - begin)
                let expectedBytes = try Self.expectedByteCount(dtype: dtype, shape: shape)
                guard byteCount == expectedBytes else {
                    throw AuditError.invalid(
                        "\(name): byte count \(byteCount) != shape/dtype count \(expectedBytes)"
                    )
                }
                guard allTensors[name] == nil else {
                    throw AuditError.invalid("duplicate tensor name across shards: \(name)")
                }
                allTensors[name] = TensorLocation(
                    name: name,
                    dtype: dtype,
                    shape: shape,
                    shardURL: shardURL,
                    payloadOffset: payloadBase + begin,
                    byteCount: byteCount
                )
                shardTensorCount += 1
            }

            shardRecords.append(
                ShardRecord(
                    url: shardURL,
                    headerLength: Int(headerLength),
                    tensorCount: shardTensorCount,
                    fileSize: fileSize
                )
            )
        }

        tensors = allTensors
        shards = shardRecords
    }

    private static func expectedByteCount(dtype: String, shape: [Int]) throws -> Int {
        let bytesPerElement: Int
        switch dtype {
        case "U8", "I8", "BOOL":
            bytesPerElement = 1
        case "BF16", "F16", "U16", "I16":
            bytesPerElement = 2
        case "F32", "U32", "I32":
            bytesPerElement = 4
        case "F64", "U64", "I64":
            bytesPerElement = 8
        default:
            throw AuditError.invalid("unsupported safetensors dtype \(dtype)")
        }
        let elements = try shape.reduce(1) { partial, dimension in
            let (next, overflow) = partial.multipliedReportingOverflow(by: dimension)
            guard !overflow else {
                throw AuditError.invalid("tensor shape overflows Int")
            }
            return next
        }
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: bytesPerElement)
        guard !overflow else {
            throw AuditError.invalid("tensor byte count overflows Int")
        }
        return bytes
    }
}

final class MappedTensor: @unchecked Sendable {
    let location: TensorLocation
    let bytes: UnsafeRawPointer

    private let fileDescriptor: Int32
    private let mapping: UnsafeMutableRawPointer
    private let mappingLength: Int

    init(_ location: TensorLocation) throws {
        self.location = location
        fileDescriptor = open(location.shardURL.path, O_RDONLY)
        guard fileDescriptor >= 0 else {
            throw AuditError.invalid(
                "\(location.shardURL.path): open failed with errno \(errno)"
            )
        }

        let pageSize = Int(getpagesize())
        let alignedOffset = location.payloadOffset / Int64(pageSize) * Int64(pageSize)
        let delta = Int(location.payloadOffset - alignedOffset)
        let (length, overflow) = delta.addingReportingOverflow(location.byteCount)
        guard !overflow else {
            close(fileDescriptor)
            throw AuditError.invalid("\(location.name): mmap length overflow")
        }
        mappingLength = length
        guard
            let mapped = mmap(
                nil,
                mappingLength,
                PROT_READ,
                MAP_PRIVATE,
                fileDescriptor,
                off_t(alignedOffset)
            ),
            mapped != MAP_FAILED
        else {
            let savedErrno = errno
            close(fileDescriptor)
            throw AuditError.invalid(
                "\(location.name): mmap failed with errno \(savedErrno)"
            )
        }
        mapping = mapped
        bytes = UnsafeRawPointer(mapped).advanced(by: delta)
    }

    deinit {
        munmap(mapping, mappingLength)
        close(fileDescriptor)
    }

    @inline(__always)
    func uint8(at byteOffset: Int) -> UInt8 {
        bytes.load(fromByteOffset: byteOffset, as: UInt8.self)
    }

    @inline(__always)
    func uint16LE(at elementIndex: Int) -> UInt16 {
        let byteOffset = elementIndex &* 2
        let low = UInt16(uint8(at: byteOffset))
        let high = UInt16(uint8(at: byteOffset + 1))
        return low | (high << 8)
    }

    @inline(__always)
    func uint32LE(at elementIndex: Int) -> UInt32 {
        let byteOffset = elementIndex &* 4
        return UInt32(uint8(at: byteOffset))
            | (UInt32(uint8(at: byteOffset + 1)) << 8)
            | (UInt32(uint8(at: byteOffset + 2)) << 16)
            | (UInt32(uint8(at: byteOffset + 3)) << 24)
    }

    func sha256() -> String {
        var digest = SHA256()
        let chunkBytes = 16 * 1_024 * 1_024
        var offset = 0
        while offset < location.byteCount {
            let count = min(chunkBytes, location.byteCount - offset)
            digest.update(
                bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.advanced(by: offset),
                    count: count
                )
            )
            offset += count
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

func sha256File(_ url: URL) throws -> String {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
        throw AuditError.invalid("\(url.path): open failed with errno \(errno)")
    }
    defer { close(descriptor) }

    // FileHandle/Data can retain autoreleased NSData chunks until this
    // command-line process drains its outer pool. Across four 5 GiB shards
    // that defeats the bounded-memory contract. One fixed POSIX buffer keeps
    // shard hashing resident memory independent of model size.
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024 * 1_024)
    var digest = SHA256()
    while true {
        let count = buffer.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress, $0.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw AuditError.invalid("\(url.path): read failed with errno \(errno)")
        }
        buffer.withUnsafeBytes {
            digest.update(
                bufferPointer: UnsafeRawBufferPointer(
                    start: $0.baseAddress,
                    count: count
                )
            )
        }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
