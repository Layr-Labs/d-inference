import Foundation
#if RADIX_CANDIDATE
@_spi(Benchmarking) import MLXLMCommon
#else
import MLXLMCommon
#endif

/// Read-only boundaries around measured cohorts. Warmup finishes before the
/// native scope is reset; observations occur outside request/batch clocks.
enum BenchmarkForwardShapes {
    struct Boundary: Sendable {
        #if RADIX_CANDIDATE
        let value: CBv2ForwardShapeSnapshot
        #endif
    }

    static func begin(_ engine: any CBv2Engine) throws -> [String: Any]? {
        #if RADIX_CANDIDATE
        guard let engine = engine as? EngineV2 else {
            throw RadixBenchmark.Failure.message("forward-shape observation requires EngineV2")
        }
        return try object(engine.beginForwardShapeObservation())
        #else
        return nil
        #endif
    }

    static func boundary(_ engine: any CBv2Engine) -> Boundary? {
        #if RADIX_CANDIDATE
        guard let engine = engine as? EngineV2 else { return nil }
        return Boundary(value: engine.forwardShapeSnapshot())
        #else
        return nil
        #endif
    }

    static func finish(_ before: Boundary?, engine: any CBv2Engine) -> [String: Any]? {
        #if RADIX_CANDIDATE
        guard let before, let engine = engine as? EngineV2 else { return nil }
        let after = engine.forwardShapeSnapshot()
        do {
            return ["schema": 1, "before": try object(before.value), "after": try object(after),
                "delta": try object(after.delta(since: before.value))]
        } catch {
            return ["schema": 1, "error": "forward_shape_encoding_failed"]
        }
        #else
        return nil
        #endif
    }

    #if RADIX_CANDIDATE
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }
    #endif
}
