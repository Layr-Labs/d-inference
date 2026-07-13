// Copyright © 2026 Eigen Labs.
//
// Provider-side mirror of the immutable inputs used to construct CBv2's
// AdmissionV2. Prepared leases consult this exact profile before start so
// admission and submit share layer geometry, watermark, and compiled-decode
// padding reserve.

import Foundation
import MLXLMCommon

public struct EngineV2PreparedAdmission: Sendable {
    private enum Estimator: Sendable {
        case layers([CBv2LayerKind], [Int])
        case flat(bytesPerToken: Int)
    }

    private let estimator: Estimator
    let watermarkFraction: Double
    let externalReserveBytes: Int

    var isSizingAvailable: Bool {
        switch estimator {
        case .layers:
            return true
        case .flat(let bytesPerToken):
            return bytesPerToken > 0
        }
    }

    public init(
        layerKinds: [CBv2LayerKind],
        config: AdmissionV2.Config = .init(),
        externalReserveBytes: Int = 0
    ) {
        let elementBytes: [Int]
        if let configured = config.layerElementBytes {
            precondition(configured.count == layerKinds.count)
            elementBytes = configured
        } else {
            elementBytes = Array(repeating: config.elementBytes, count: layerKinds.count)
        }
        estimator = .layers(layerKinds, elementBytes)
        watermarkFraction = config.watermarkFraction
        self.externalReserveBytes = max(0, externalReserveBytes)
    }

    init(
        flatKVBytesPerToken: Int,
        config: AdmissionV2.Config = .init(),
        externalReserveBytes: Int = 0
    ) {
        estimator = .flat(bytesPerToken: max(0, flatKVBytesPerToken))
        watermarkFraction = config.watermarkFraction
        self.externalReserveBytes = max(0, externalReserveBytes)
    }

    func estimatedBytes(forTokens tokens: Int) -> UInt64? {
        guard tokens > 0 else { return 0 }
        switch estimator {
        case .flat(let bytesPerToken):
            let (bytes, overflow) = UInt64(tokens)
                .multipliedReportingOverflow(by: UInt64(bytesPerToken))
            return overflow ? nil : bytes
        case .layers(let layerKinds, let elementBytes):
            var total: UInt64 = 0
            for (index, kind) in layerKinds.enumerated()
            where kind.sharesKVWithLayer == nil {
                let retained: Int
                switch kind.attention {
                case .full:
                    retained = tokens
                case .slidingWindow(let window):
                    retained = min(tokens, window)
                }
                let factors = [
                    UInt64(retained),
                    2,
                    UInt64(kind.kvHeads),
                    UInt64(kind.headDim),
                    UInt64(elementBytes[index]),
                ]
                var layerBytes: UInt64 = 1
                for factor in factors {
                    let (product, overflow) =
                        layerBytes.multipliedReportingOverflow(by: factor)
                    guard !overflow else { return nil }
                    layerBytes = product
                }
                let (sum, overflow) = total.addingReportingOverflow(layerBytes)
                guard !overflow else { return nil }
                total = sum
            }
            return total
        }
    }

    func admissibleBytesCapacity(totalCapacity: Int) -> Int {
        let capacity = max(0, totalCapacity)
        let watermark = Int(Double(capacity) * watermarkFraction)
        return capacity - externalReserveBytes - watermark
    }
}

protocol EngineV2PreparedAdmissionProviding {
    var preparedAdmission: EngineV2PreparedAdmission { get }
}

final class PreparedAdmissionCBv2Engine:
    CBv2Engine, EngineV2PreparedAdmissionProviding, @unchecked Sendable
{
    private let engine: any CBv2Engine
    let preparedAdmission: EngineV2PreparedAdmission

    init(engine: any CBv2Engine, preparedAdmission: EngineV2PreparedAdmission) {
        self.engine = engine
        self.preparedAdmission = preparedAdmission
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        try engine.submit(request)
    }

    func cancel(_ id: CBv2RequestID) {
        engine.cancel(id)
    }

    func capacity() -> CBv2CapacitySnapshot {
        engine.capacity()
    }

    func updateKVBytesCapacity(_ bytes: Int) {
        engine.updateKVBytesCapacity(bytes)
    }

    func shutdown() async {
        await engine.shutdown()
    }
}
