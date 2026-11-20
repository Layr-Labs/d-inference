import Darwin
import Foundation

/// Reuses the qualified phase export's fixed malloc buffer and synchronous
/// no-copy publication pattern. No growing Data or general JSON encoder is used.
final class QwenProtectedEvidenceJSON {
    final class Release: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.lock(); done = true; lock.unlock() }
        var released: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }
    private var storage: UnsafeMutableRawPointer?
    private(set) var count = 0

    init() throws {
        guard let pointer = malloc(QwenProtectedEvidenceBudget.maximumEncodedBytes) else {
            throw ProbeError("Protected evidence output allocation failed")
        }
        do { try QwenProtectedEvidenceBudget.requireAllocation(malloc_size(pointer)) }
        catch { free(pointer); throw error }
        storage = pointer
    }

    func raw(_ value: String) throws {
        guard let storage, value.utf8.count <= 1024,
              value.utf8.count <= QwenProtectedEvidenceBudget.maximumEncodedBytes - count else {
            throw ProbeError("Protected evidence exceeds fixed output capacity")
        }
        for byte in value.utf8 {
            storage.storeBytes(of: byte, toByteOffset: count, as: UInt8.self); count += 1
        }
    }
    func string(_ value: String) throws {
        guard value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 34 && $0 != 92 }) else {
            throw ProbeError("Protected evidence string differs from its closed ASCII schema")
        }
        try raw("\""); try raw(value); try raw("\"")
    }
    func key(_ value: String) throws { try string(value); try raw(":") }
    func integer<T: BinaryInteger>(_ value: T) throws { try raw(String(value)) }
    func floating(_ value: Float) throws {
        guard value.isFinite else { throw ProbeError("Protected evidence has a nonfinite logit") }
        let text = String(value)
        guard text.utf8.count <= 32 else { throw ProbeError("Protected evidence Float32 spelling exceeds bound") }
        try raw(text)
    }
    func field(_ key: String, _ value: String, comma: Bool = true) throws {
        try self.key(key); try string(value); if comma { try raw(",") }
    }
    func number<T: BinaryInteger>(_ key: String, _ value: T, comma: Bool = true) throws {
        try self.key(key); try integer(value); if comma { try raw(",") }
    }
    func flag(_ key: String, _ value: Bool, comma: Bool = true) throws {
        try self.key(key); try raw(value ? "true" : "false"); if comma { try raw(",") }
    }
    func integers(_ values: [Int]) throws {
        guard values.count <= 32 else { throw ProbeError("Protected evidence integer array exceeds bound") }
        try raw("[")
        for (index, value) in values.enumerated() {
            if index > 0 { try raw(",") }; try integer(value)
        }
        try raw("]")
    }
    private func transfer(release: Release) throws -> Data {
        guard let pointer = storage, count > 0 else {
            throw ProbeError("Empty or repeated protected evidence transfer")
        }
        storage = nil
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
            free(pointer); release.mark()
        })
    }
    func publish(_ body: (Data) throws -> Void) throws {
        let release = Release()
        try autoreleasepool { try body(transfer(release: release)) }
        guard release.released else { throw ProbeError("Protected evidence publisher retained its reserved output buffer") }
    }
    deinit { if let storage { free(storage) } }
}
