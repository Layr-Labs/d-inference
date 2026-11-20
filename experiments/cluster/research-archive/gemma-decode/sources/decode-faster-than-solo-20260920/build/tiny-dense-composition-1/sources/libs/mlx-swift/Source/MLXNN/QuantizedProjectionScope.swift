import Foundation
import MLX

/// Private synchronous graph-construction hook. It is not inherited by tasks or
/// threads, stores no model weights, and restores the previous empty scope even
/// when graph construction throws. Callers must NOT evaluate inside `body`.
@_spi(QuantizedProjectionScope)
public enum QuantizedProjectionScope {
    public enum Kind { case linear, embeddingHead }
    public struct Input {
        public let module: ObjectIdentifier
        public let kind: Kind
        public let input: MLXArray
        public let weight: MLXArray
        public let scales: MLXArray
        public let biases: MLXArray?
        public let groupSize: Int
        public let bits: Int
        public let mode: QuantizationMode
    }
    public enum Failure: Error { case nestedScope, recursiveProjection }
    private static let key = "org.mlx-swift.quantized-projection-synchronous-scope.v1"
    private final class Box: NSObject {
        var handler: ((Input) throws -> MLXArray?)?
        var failure: Error?
        var projecting = false
        init(_ handler: @escaping (Input) throws -> MLXArray?) { self.handler = handler }
    }
    static var isActive: Bool { Thread.current.threadDictionary[key] != nil }

    /// Nonthrowing layer APIs cannot propagate a handler error directly. The
    /// first error is latched, ordinary LAZY graph construction can unwind, and
    /// this function throws before returning that graph to its evaluator.
    public static func withHandler<Result>(_ handler: (Input) throws -> MLXArray?,
                                          body: () throws -> Result) throws -> Result {
        guard !isActive else { throw Failure.nestedScope }
        return try withoutActuallyEscaping(handler) { borrowed in
            let box = Box(borrowed)
            let dictionary = Thread.current.threadDictionary
            dictionary[key] = box
            defer {
                dictionary.removeObject(forKey: key)
                // Foundation may extend the box's lifetime through autorelease;
                // the borrowed handler must end HERE, before the scope returns.
                box.handler = nil
            }
            do {
                let result = try body()
                if let failure = box.failure { throw failure }
                return result
            } catch { throw box.failure ?? error }
        }
    }

    static func project(module: Module, kind: Kind, input: MLXArray,
                        weight: MLXArray, scales: MLXArray, biases: MLXArray?,
                        groupSize: Int, bits: Int, mode: QuantizationMode) -> MLXArray? {
        guard let box = Thread.current.threadDictionary[key] as? Box,
              box.failure == nil, let handler = box.handler else { return nil }
        guard !box.projecting else {
            box.failure = Failure.recursiveProjection
            return nil
        }
        box.projecting = true
        defer { box.projecting = false }
        do {
            return try handler(.init(module: ObjectIdentifier(module), kind: kind,
                input: input, weight: weight, scales: scales, biases: biases,
                groupSize: groupSize, bits: bits, mode: mode))
        } catch {
            if box.failure == nil { box.failure = error }
            return nil
        }
    }
}
