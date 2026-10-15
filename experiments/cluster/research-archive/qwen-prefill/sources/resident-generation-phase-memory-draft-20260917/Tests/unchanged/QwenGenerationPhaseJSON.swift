import Darwin
import Foundation

/// Single fixed malloc output buffer. No general JSON object graph, growing
/// Data or encoder scratch is created. Decimal/string temporaries are bounded
/// by the closed schema and covered by the named metadata/scratch allowance.
final class QwenGenerationPhaseJSON {
    final class Release: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.lock(); done = true; lock.unlock() }
        var released: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }
    private var storage: UnsafeMutableRawPointer?
    private let capacity: Int
    private(set) var count = 0

    init(budget: QwenGenerationPhaseBudget) throws {
        capacity = QwenGenerationPhaseBudget.maximumEncodedBytes
        guard capacity > 0, budget.encodedResultAllocationBytes >= capacity,
              let pointer = malloc(capacity) else { throw QwenGenerationPhaseError("Phase output allocation failed") }
        guard malloc_size(pointer) <= budget.encodedResultAllocationBytes else {
            free(pointer); throw QwenGenerationPhaseError("Actual phase output allocation exceeds reservation")
        }
        storage = pointer
    }

    func raw(_ string: String) throws {
        guard let storage, string.utf8.count <= 1024, string.utf8.count <= capacity - count else {
            throw QwenGenerationPhaseError("Phase JSON output exceeds fixed capacity")
        }
        for byte in string.utf8 { storage.storeBytes(of: byte, toByteOffset: count, as: UInt8.self); count += 1 }
    }
    func string(_ value: String) throws {
        guard value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 34 && $0 != 92 }) else {
            throw QwenGenerationPhaseError("Phase JSON string is outside the closed ASCII schema")
        }
        try raw("\""); try raw(value); try raw("\"")
    }
    func key(_ name: String) throws { try string(name); try raw(":") }
    func integer<T: BinaryInteger>(_ value: T) throws { try raw(String(value)) }
    func field(_ name: String, _ value: String, comma: Bool = true) throws {
        try key(name); try string(value); if comma { try raw(",") }
    }
    func number<T: BinaryInteger>(_ name: String, _ value: T, comma: Bool = true) throws {
        try key(name); try integer(value); if comma { try raw(",") }
    }
    func flag(_ name: String, _ value: Bool, comma: Bool = true) throws {
        try key(name); try raw(value ? "true" : "false"); if comma { try raw(",") }
    }
    func optionalNumber(_ name: String, _ value: Int?, comma: Bool = true) throws {
        try key(name)
        if let value { try integer(value) } else { try raw("null") }
        if comma { try raw(",") }
    }

    /// Ownership transfers to Data exactly once. The export checks that its
    /// custom release ran after the synchronous publisher's scope drained.
    func transfer(release: Release) throws -> Data {
        guard let pointer = storage, count > 0 else { throw QwenGenerationPhaseError("Empty or repeated phase JSON transfer") }
        storage = nil
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
            free(pointer); release.mark()
        })
    }
    func publish(_ body: (Data) throws -> Void) throws {
        let release = Release()
        try autoreleasepool {
            let bytes = try transfer(release: release)
            try body(bytes)
        }
        guard release.released else { throw QwenGenerationPhaseError("Phase publisher retained its reserved output buffer") }
    }
    deinit { if let storage { free(storage) } }
}
