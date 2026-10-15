import Foundation

/// Enumerates simultaneously retained allocations. No roots or allocator are
/// created here. The runtime must call admit with its REAL allocator upper
/// bound and exact original snapshot terms BEFORE receiving/assembling arrays.
struct Gemma4MTPDeltaAllocationPlan: Equatable {
    struct Root: Equatable {
        let name: String
        let shape: [Int]
        let elementBytes: Int
        let logicalBytes: Int
        init(_ name: String, _ shape: [Int], _ elementBytes: Int = 2) throws {
            self.name = name; self.shape = shape; self.elementBytes = elementBytes
            logicalBytes = try Gemma4MTPDeltaBytes.product(shape + [elementBytes])
        }
    }
    struct ReservedTerm: Equatable {
        let name: String
        let logicalBytes: Int
        let allocationBound: Int
    }
    struct Admission: Equatable {
        let roots: [ReservedTerm]
        let originalSnapshotTerms: [ReservedTerm]
        let requiredBytes: Int
        let reservedBytes: Int
    }
    let descriptor: Gemma4MTPDeltaDescriptor
    let oldMirror: [Root]
    let received: [Root]
    let assembled: [Root]
    let expectedOriginalSnapshotTerms: [Root]
    var roots: [Root] { oldMirror + received + assembled }
    var tensorBytes: Int { get throws { try Gemma4MTPDeltaBytes.sum(received.map(\.logicalBytes)) } }
    var logicalLiveBytes: Int { get throws { try Gemma4MTPDeltaBytes.sum(roots.map(\.logicalBytes)) } }

    init(envelope: Gemma4MTPDeltaEnvelope, descriptor: Gemma4MTPDeltaDescriptor) throws {
        // Re-derive to refuse descriptors from a different envelope.
        guard try Gemma4MTPDeltaDescriptor(envelope: envelope, base: descriptor.base,
                                         next: descriptor.next) == descriptor else {
            throw Gemma4MTPDeltaError.range
        }
        self.descriptor = descriptor
        func kv(_ prefix: String, _ frontier: Int) throws -> [Root] {
            try [Root(prefix + ".fullKeys", [1, 2, frontier, 512]),
                 Root(prefix + ".fullValues", [1, 2, frontier, 512]),
                 Root(prefix + ".slidingKeys", [1, 8, min(frontier, 1024), 256]),
                 Root(prefix + ".slidingValues", [1, 8, min(frontier, 1024), 256])]
        }
        oldMirror = try kv("old", descriptor.base.frontier)
        let d = descriptor.appended.count
        received = try [Root("received.hidden", [1, 1, 2816], descriptor.next.hiddenDType == 3 ? 4 : 2),
                        Root("received.fullKeys", [1, 2, d, 512]),
                        Root("received.fullValues", [1, 2, d, 512]),
                        Root("received.slidingKeys", [1, 8, d, 256]),
                        Root("received.slidingValues", [1, 8, d, 256])]
        assembled = try kv("assembled", descriptor.next.frontier)
        guard received.allSatisfy({ $0.logicalBytes <= 16 * 1024 * 1024 }) else {
            throw Gemma4MTPDeltaError.range
        }
        var original: [Root] = []
        for copy in 0..<3 {
            for component in ["keys", "values"] {
                original.append(try Root("snapshot\(copy):full:" + component,
                                         [envelope.maximumFrontier, 2, 512]))
                original.append(try Root("snapshot\(copy):sliding:" + component,
                                         [min(envelope.maximumFrontier, 1024), 8, 256]))
            }
        }
        expectedOriginalSnapshotTerms = original
    }

    func admit(originalSnapshotTerms: [ReservedTerm],
               allocationBound: (Int) throws -> Int) throws -> Admission {
        guard originalSnapshotTerms.count == 12,
              Set(originalSnapshotTerms.map(\.name)).count == 12 else {
            throw Gemma4MTPDeltaError.allowance
        }
        let saved = Dictionary(uniqueKeysWithValues: originalSnapshotTerms.map { ($0.name, $0) })
        var original: [ReservedTerm] = []
        for expected in expectedOriginalSnapshotTerms {
            let actual = try allocationBound(expected.logicalBytes)
            guard let retained = saved[expected.name], actual >= expected.logicalBytes,
                  retained.logicalBytes == expected.logicalBytes,
                  retained.allocationBound == actual else { throw Gemma4MTPDeltaError.allowance }
            original.append(retained)
        }
        // 13 independent calls: never bound(sum(logicalBytes)) or infer that
        // a three-copy label proves arbitrary per-allocation rounding fits.
        let required = try roots.map { root -> ReservedTerm in
            let actual = try allocationBound(root.logicalBytes)
            guard actual >= root.logicalBytes else { throw Gemma4MTPDeltaError.allowance }
            return .init(name: root.name, logicalBytes: root.logicalBytes, allocationBound: actual)
        }
        let requiredBytes = try Gemma4MTPDeltaBytes.sum(required.map(\.allocationBound))
        let reservedBytes = try Gemma4MTPDeltaBytes.sum(original.map(\.allocationBound))
        guard required.count == 13, requiredBytes <= reservedBytes else { throw Gemma4MTPDeltaError.allowance }
        return .init(roots: required, originalSnapshotTerms: original,
                     requiredBytes: requiredBytes, reservedBytes: reservedBytes)
    }
}
