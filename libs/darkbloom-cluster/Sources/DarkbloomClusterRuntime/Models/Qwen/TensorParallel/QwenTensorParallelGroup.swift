import Cmlx
import Foundation
import MLX

/// The rank group of a tensor-parallel run.
///
/// `jaccl` is RDMA over Thunderbolt between two Macs (strict: no fallback).
/// `ring` is MLX's TCP ring between two ranks on ONE Mac over 127.0.0.1
/// (`MLX_RANK`, `MLX_HOSTFILE`); it carries real reductions, so it qualifies a
/// tensor-parallel run's arithmetic and control on one Mac, and it is never a
/// pair timing or a hardware pass. `socket` is the same qualification without
/// MLX's ring (absent from some builds): one TCP connection over 127.0.0.1
/// (`QwenTensorParallelLocalSocket`), every reduction eager and summed on the
/// CPU in rank order (IEEE addition of two values is commutative, so the sum
/// equals JACCL's), correctness only.
public final class QwenTensorParallelGroup: QwenTensorParallelReduction {
    public enum Backend: String, Sendable, CaseIterable {
        case jaccl
        case ring
        case socket

        /// Two ranks on one Mac: qualifies arithmetic and control, never a timing.
        public var correctnessOnly: Bool { self != .jaccl }
    }

    public let backend: Backend
    public let rank: Int
    public let size: Int
    private let handle: mlx_distributed_group?
    private let link: QwenTensorParallelLocalSocket?
    /// The product's group: the resident load's own collective (its JACCL
    /// group, created through the owner's bootstrap), borrowed, never freed
    /// here. Its keyed data plane forbids any plaintext floating reduction.
    private let collective: Collective?
    public private(set) var floatingReductions = 0
    /// When set, every floating all-sum crosses the link sealed by this codec
    /// (`mlx_distributed_all_sum_sealed`); integer agreements stay plain.
    public var sealed: QwenTensorParallelSealCodec?

    /// The product: the reductions of a resident tensor-parallel load run on
    /// its collective's group. With a keyed data plane the floating
    /// reductions must be sealed (`sealed`), and integer agreements cross
    /// sealed too (as float32, exact below 2^24), so no byte of a keyed
    /// session crosses the cable in the clear.
    init(collective: Collective) throws {
        guard collective.transport == .jaccl, collective.size == 2 else {
            throw ProbeError("A product tensor-parallel group runs on a two-rank JACCL collective")
        }
        self.collective = collective; link = nil; handle = collective.handle
        backend = .jaccl; rank = collective.rank; size = collective.size
    }

    /// True when every floating reduction must be sealed (a keyed data plane).
    var requiresSealing: Bool { collective?.protectionRequired ?? false }

    public init(backend: Backend) throws {
        collective = nil
        if backend.correctnessOnly { try Self.validateLocalRing() }
        if backend == .socket {
            let (rank, port) = try Self.localSocketEndpoint()
            link = try QwenTensorParallelLocalSocket(rank: rank, port: port)
            handle = nil
            self.backend = backend
            self.rank = rank
            size = 2
            return
        }
        link = nil
        guard mlx_distributed_is_available(backend.rawValue) else {
            throw ProbeError("The \(backend.rawValue) backend is not available in this build; no fallback is allowed")
        }
        var initialized = mlx_distributed_group_new()
        try MLX.withError { error in
            let status = mlx_distributed_init(&initialized, true, backend.rawValue)
            try error.check()
            guard status == 0 else { throw ProbeError("\(backend.rawValue) initialization failed: \(status)") }
        }
        handle = initialized
        self.backend = backend
        rank = Int(mlx_distributed_group_rank(initialized))
        size = Int(mlx_distributed_group_size(initialized))
        guard size == 2, (0..<size).contains(rank) else {
            // Fully initialized: deinit frees the group (an explicit free here would free it twice).
            throw ProbeError("Tensor parallel runs exactly two ranks, got rank=\(rank) size=\(size)")
        }
    }

    deinit { if collective == nil, let handle { mlx_distributed_group_free(handle) } }

    /// Unevaluated all-sum on the CPU stream: the graph decides when it runs.
    public func allSum(_ value: MLXArray) -> MLXArray {
        if [.float16, .bfloat16, .float32].contains(value.dtype) { floatingReductions += 1 }
        guard let handle else { return socketAllSum(value) }
        let floating = [.float16, .bfloat16, .float32].contains(value.dtype)
        if requiresSealing {
            // A keyed session: nothing crosses in the clear. Integers travel as
            // float32 (exact for |x| < 2^24, which every agreement keeps to).
            precondition(sealed != nil, "A keyed data plane carries sealed tensor-parallel reductions only")
            if !floating { return allSum(value.asType(.float32)).asType(value.dtype) }
        }
        var result = mlx_array_new()
        let status = sealed != nil && floating
            ? mlx_distributed_all_sum_sealed(&result, value.ctx, handle, StreamOrDevice.cpu.ctx)
            : mlx_distributed_all_sum(&result, value.ctx, handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "\(backend.rawValue) all-sum graph construction failed")
        return MLXArray(result)
    }

    /// Unevaluated: this rank's half of the sum of both ranks' `[1, T, ...]`
    /// floating partials, rows `rank * T / 2 ..< (rank + 1) * T / 2` (T even),
    /// each element added in rank order as `allSum` adds it. Sealed, each rank
    /// sends only the peer's half (`mlx_distributed_reduce_scatter_sealed`);
    /// unsealed (a bench), the whole sum's rows.
    public func reduceScatter(_ value: MLXArray) -> MLXArray {
        precondition(size == 2 && value.ndim >= 2 && value.dim(0) == 1 && value.dim(1) % 2 == 0
            && [.float16, .bfloat16, .float32].contains(value.dtype), "reduce-scatter takes [1, T, ...] floats, T even")
        let half = value.dim(1) / 2
        guard let handle, let _ = sealed else {
            return allSum(value)[0..., (rank * half) ..< ((rank + 1) * half)]
        }
        floatingReductions += 1
        var result = mlx_array_new()
        let status = mlx_distributed_reduce_scatter_sealed(&result, value.ctx, handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "\(backend.rawValue) reduce-scatter graph construction failed")
        return MLXArray(result)
    }

    /// Unevaluated: both ranks' `[1, T, ...]` rows as `[1, 2T, ...]`, rank 0's
    /// first, every element's bits kept. Sealed, each rank sends only its own
    /// (`mlx_distributed_all_gather_sealed`); unsealed (a bench), a sum of
    /// frames padded with -0 (x + -0 is x).
    public func allGather(_ value: MLXArray) -> MLXArray {
        precondition(size == 2 && value.ndim >= 2 && value.dim(0) == 1
            && [.float16, .bfloat16, .float32].contains(value.dtype), "all-gather takes [1, T, ...] floats")
        guard let handle, let _ = sealed else {
            let padding = MLX.full(value.shape, values: MLXArray(Float(-0.0)).asType(value.dtype))
            return allSum(concatenated(rank == 0 ? [value, padding] : [padding, value], axis: 1))
        }
        floatingReductions += 1
        var result = mlx_array_new()
        let status = mlx_distributed_all_gather_sealed(&result, value.ctx, handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "\(backend.rawValue) all-gather graph construction failed")
        return MLXArray(result)
    }

    /// Evaluated now: the elementwise sum of every rank's integers (each rank
    /// fills its own slots, the others zero).
    public func exchangeIntegers(_ values: [Int32]) throws -> [Int32] {
        let combined = allSum(MLXArray(values))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        return combined.asArray(Int32.self)
    }

    /// Evaluated now; the caller learns whether every rank passed the same values.
    public func agree(_ values: [Int32]) throws -> Bool {
        let combined = allSum(MLXArray(values))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        return combined.asArray(Int32.self) == values.map { $0 &* Int32(size) }
    }

    /// Both ranks learn whether they hold the same 64-bit digest. Each rank
    /// fills its own slot with the digest's four 16-bit pieces.
    public func digestsEqual(_ digest: UInt64) throws -> Bool {
        var slots = [Int32](repeating: 0, count: 4 * size)
        for piece in 0..<4 { slots[rank * 4 + piece] = Int32((digest >> (16 * UInt64(piece))) & 0xFFFF) }
        let combined = allSum(MLXArray(slots))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        let all = combined.asArray(Int32.self)
        return (1..<size).allSatisfy { other in Array(all[(other * 4)..<(other * 4 + 4)]) == Array(all[0..<4]) }
    }

    /// Largest single point-to-point message; longer buffers go in pieces.
    public static let maximumMessageBytes = 16 << 20

    /// A one-dimensional buffer to `peer`, byte for byte, in pieces; returns when sent.
    public func send(_ value: MLXArray, to peer: Int) throws {
        guard value.ndim == 1, peer != rank, (0..<size).contains(peer) else {
            throw ProbeError("Tensor parallel send: a one-dimensional buffer to another rank")
        }
        eval(value)
        if let link {
            try link.send(value.asData(access: .copy).data)
            return
        }
        let per = max(1, Self.maximumMessageBytes / value.itemSize)
        var start = 0
        while start < value.size {
            let piece = value[start ..< min(value.size, start + per)]
            var result = mlx_array_new()
            try MLX.withError { error in
                let status = mlx_distributed_send(&result, piece.ctx, Int32(peer), handle!, StreamOrDevice.cpu.ctx)
                try error.check()
                guard status == 0 else { throw ProbeError("send graph construction failed: \(status)") }
                let sent = MLXArray(result)
                eval(sent)
                try error.check()
            }
            start += per
        }
    }

    /// The matching receive of `count` elements of `dtype` from `peer`.
    public func receive(count: Int, dtype: DType, from peer: Int) throws -> MLXArray {
        guard count > 0, peer != rank, (0..<size).contains(peer) else {
            throw ProbeError("Tensor parallel receive: a positive count from another rank")
        }
        let native: mlx_dtype
        switch dtype {
        case .bfloat16: native = MLX_BFLOAT16
        case .float16: native = MLX_FLOAT16
        case .float32: native = MLX_FLOAT32
        case .int32: native = MLX_INT32
        default: throw ProbeError("Tensor parallel receive: unsupported dtype \(dtype)")
        }
        if let link {
            return MLXArray(try link.receive(count: count * dtype.size), [count], dtype: dtype)
        }
        let per = max(1, Self.maximumMessageBytes / dtype.size)
        var pieces: [MLXArray] = []
        var start = 0
        while start < count {
            let length = min(count - start, per)
            var result = mlx_array_new()
            let shape = [Int32(length)]
            try MLX.withError { error in
                let status = shape.withUnsafeBufferPointer {
                    mlx_distributed_recv(&result, $0.baseAddress, $0.count, native, Int32(peer), handle!, StreamOrDevice.cpu.ctx)
                }
                try error.check()
                guard status == 0 else { throw ProbeError("recv graph construction failed: \(status)") }
                let received = MLXArray(result)
                eval(received)
                try error.check()
                pieces.append(received)
            }
            start += length
        }
        return pieces.count == 1 ? pieces[0] : concatenated(pieces, axis: 0)
    }

    /// The socket backend's reduction: this rank's buffer evaluated now and
    /// exchanged whole, then `rank 0 + rank 1` on the CPU stream. A link failure
    /// ends the process (a reduction cannot return a partial result).
    private func socketAllSum(_ value: MLXArray) -> MLXArray {
        let mine = value.asData(access: .copy)
        let theirs: Data
        do { theirs = try link!.exchange(mine.data) } catch {
            fatalError("tensor-parallel socket reduction failed: \(error)")
        }
        let other = MLXArray(theirs, mine.shape, dtype: mine.dType)
        let local = MLXArray(mine.data, mine.shape, dtype: mine.dType)
        return rank == 0 ? add(local, other, stream: .cpu) : add(other, local, stream: .cpu)
    }

    /// The socket backend: this rank (MLX_RANK) and rank 0's listening port
    /// (the host file's first endpoint).
    private static func localSocketEndpoint() throws -> (Int, UInt16) {
        let environment = ProcessInfo.processInfo.environment
        let file = environment["MLX_HOSTFILE"] ?? ""
        let hosts = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        guard let rank = Int(environment["MLX_RANK"] ?? ""),
              let port = UInt16(hosts[0][0].dropFirst("127.0.0.1:".count)), port > 1023 else {
            throw ProbeError("The local socket needs MLX_RANK and a 127.0.0.1 port above 1023 in MLX_HOSTFILE")
        }
        return (rank, port)
    }

    /// The local ring may only open two IPv4 loopback endpoints.
    private static func validateLocalRing() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rankText = environment["MLX_RANK"], ["0", "1"].contains(rankText),
              let file = environment["MLX_HOSTFILE"], !file.isEmpty else {
            throw ProbeError("The local ring requires MLX_RANK=0|1 and MLX_HOSTFILE")
        }
        let hosts = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        guard hosts.count == 2, hosts.allSatisfy({ $0.count == 1 && $0[0].hasPrefix("127.0.0.1:") }),
              Set(hosts.map { $0[0] }).count == 2 else {
            throw ProbeError("The local ring requires exactly two distinct 127.0.0.1:port endpoints")
        }
    }
}
