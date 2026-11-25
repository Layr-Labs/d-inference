import CryptoKit
import Foundation

/// UTF-8 text the provider gathers while it streams a response (the output the
/// response hash covers, the delivered text for the cancelled-stream billing
/// floor, reasoning for its token count), in storage it owns. Growing zeroes
/// the storage it leaves, and the text is zeroed when the buffer is released.
/// One owner at a time: callers that share it hold their own lock.
final class ResponseTextBuffer {
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0
    private(set) var count = 0

    deinit {
        guard let storage else { return }
        secureZero(UnsafeMutableRawBufferPointer(start: storage, count: count))
        storage.deallocate()
    }

    var isEmpty: Bool { count == 0 }

    func append(_ text: some StringProtocol) {
        append(utf8: text.utf8)
    }

    func append(utf8 bytes: some Collection<UInt8>) {
        let appended: Void? = bytes.withContiguousStorageIfAvailable { append(UnsafeRawBufferPointer($0)) }
        if appended == nil {
            // A bridged string has no contiguous UTF-8: copy once, then zero the copy.
            var copy = Array(bytes)
            defer { copy.withUnsafeMutableBytes { secureZero($0) } }
            copy.withUnsafeBytes { append($0) }
        }
    }

    func append(contentsOf other: ResponseTextBuffer) {
        precondition(other !== self, "a buffer cannot append itself")
        guard let source = other.storage else { return }
        append(UnsafeRawBufferPointer(start: source, count: other.count))
    }

    /// SHA-256 of `prefix` followed by the text, without copying the text.
    func sha256(after prefix: String) -> SHA256.Digest {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        if let storage {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: storage, count: count))
        }
        return hasher.finalize()
    }

    /// Calls `body` with the text as a `String`, for an API that takes one (the
    /// tokenizer). That `String` is a separate copy that is not zeroed, so keep
    /// it to the call.
    func withText<R>(_ body: (String) throws -> R) rethrows -> R {
        guard let storage else { return try body("") }
        return try body(String(decoding: UnsafeRawBufferPointer(start: storage, count: count), as: UTF8.self))
    }

    private func append(_ bytes: UnsafeRawBufferPointer) {
        guard let source = bytes.baseAddress, !bytes.isEmpty else { return }
        reserve(count + bytes.count)
        storage!.advanced(by: count).copyMemory(from: source, byteCount: bytes.count)
        count += bytes.count
    }

    private func reserve(_ needed: Int) {
        guard needed > capacity else { return }
        let grown = max(needed, capacity * 2, 256)
        let replacement = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 1)
        if let storage {
            replacement.copyMemory(from: storage, byteCount: count)
            secureZero(UnsafeMutableRawBufferPointer(start: storage, count: count))
            storage.deallocate()
        }
        storage = replacement
        capacity = grown
    }
}
