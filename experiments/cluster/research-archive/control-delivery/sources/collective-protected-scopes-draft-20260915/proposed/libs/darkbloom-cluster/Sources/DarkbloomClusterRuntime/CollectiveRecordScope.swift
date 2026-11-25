import CryptoKit
import DarkbloomClusterSecurity
import Foundation

/// Immutable local expectation. Nothing here is adopted from an unauthenticated peer.
struct CollectiveRequestScope {
    let requestID: UUID
    let epoch: UUID
    let planSHA256: Data
    let agreementSHA256: Data

    init(requestID: UUID, epoch: UUID, planSHA256: String, agreementSHA256: String) throws {
        self.requestID = requestID; self.epoch = epoch
        self.planSHA256 = try collectiveRecordDigest(planSHA256)
        self.agreementSHA256 = try collectiveRecordDigest(agreementSHA256)
        _ = try ClusterRecordContext(requestID: requestID, type: .requestAgreement, expectationSHA256: self.agreementSHA256)
    }

    func operation(_ type: ClusterRecordType, metadata: Data) throws -> CollectiveOperationScope {
        guard metadata.count <= 16_384 else { throw ProbeError("Protected operation metadata exceeds its bound") }
        var bytes = Data("darkbloom/collective/request-operation/v1\0".utf8)
        bytes.append(agreementSHA256); bytes.append(metadata)
        let context = try ClusterRecordContext(requestID: requestID, type: type,
            expectationSHA256: Data(SHA256.hash(data: bytes)))
        return .init(request: self, context: context)
    }
}

struct CollectiveOperationScope {
    enum Part: UInt8 { case array = 1, controlLength, controlBody }
    let request: CollectiveRequestScope?
    let context: ClusterRecordContext

    fileprivate init(request: CollectiveRequestScope?, context: ClusterRecordContext) {
        self.request = request; self.context = context
    }

    static func setup(_ type: ClusterRecordType, agreementSHA256: String) throws -> Self {
        .init(request: nil, context: try .init(requestID: nil, type: type,
            expectationSHA256: collectiveRecordDigest(agreementSHA256)))
    }

    func part(_ part: Part) throws -> Self {
        var bytes = Data("darkbloom/collective/operation-part/v1\0".utf8)
        bytes.append(context.expectationSHA256); bytes.append(part.rawValue)
        return .init(request: request, context: try .init(requestID: context.requestID, type: context.type,
            expectationSHA256: Data(SHA256.hash(data: bytes))))
    }

    func requireBinding(_ binding: ClusterRecordBinding) throws {
        if let request {
            guard request.epoch == binding.epoch, request.planSHA256 == binding.planSHA256 else {
                throw ProbeError("Protected operation differs from its fixed session binding")
            }
        }
    }
}

func collectiveRecordDigest(_ text: String) throws -> Data {
    let values = Array(text.utf8)
    guard values.count == 64, values.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw ProbeError("Protected operation requires a canonical SHA256 identity")
    }
    func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
    return Data(stride(from: 0, to: 64, by: 2).map { digit(values[$0]) * 16 + digit(values[$0 + 1]) })
}
