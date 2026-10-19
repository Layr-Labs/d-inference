import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM calibration admission", .serialized)
struct GLM5NextCalibrationTests {
    enum Failure: Error { case unauthorized }
    func authorization(ceiling: Int = 8 << 30) throws -> GLM5NextCalibration.Authorization {
        try .init(requestID: UUID(), nativeHardCapBytes: ceiling, hostBudgetBytes: 1 << 30, osHeadroomBytes: 1 << 30,
            workspaceNativeAllowanceBytes: 1 << 20, workspaceHostAllowanceBytes: 1 << 20,
            promptTokenIDs: [1, 2], outputCount: 1, chunkSize: 2)
    }
    @Test func invalidCapacityAndUnboundedRequestsRefuse() throws {
        #expect(throws: (any Error).self) { try authorization(ceiling: 1 << 20) }
        #expect(throws: (any Error).self) {
            try GLM5NextCalibration.Authorization(requestID: UUID(), nativeHardCapBytes: Int.max, hostBudgetBytes: 1, osHeadroomBytes: 1,
                workspaceNativeAllowanceBytes: Int.max, workspaceHostAllowanceBytes: 1,
                promptTokenIDs: [1], outputCount: 1, chunkSize: 1)
        }
        #expect(throws: (any Error).self) {
            try GLM5NextCalibration.Authorization(requestID: UUID(), nativeHardCapBytes: 1 << 30, hostBudgetBytes: 1 << 20, osHeadroomBytes: 1 << 20,
                workspaceNativeAllowanceBytes: 1, workspaceHostAllowanceBytes: 1,
                promptTokenIDs: Array(repeating: 1, count: 2049), outputCount: 1, chunkSize: 1)
        }
    }
    @Test func quotationUsesResidentMathAndCannotBecomeServingEvidence() throws {
        let fixture = try GLM5NextResidentRuntimeTests.Fixture()
        let environment = String(repeating: "e", count: 64)
        func plan(_ auth: GLM5NextCalibration.Authorization, authenticate: () throws -> Void = {}) throws
            -> GLM5NextCalibration.Plan {
            try GLM5NextCalibration.plan(descriptor: fixture.descriptor,
                inventory: fixture.artifact.metadata.inventory, rank: 0, authorization: auth,
                authorizationSHA256: String(repeating: "a", count: 64), executionEnvironmentSHA256: environment,
                authenticate: authenticate, requireEnvironment: { _ in }, maximumBufferBytes: Int.max,
                allocationBound: { $0 }, hostAllocationBound: { $0 })
        }
        #expect(throws: Failure.unauthorized) { try plan(authorization(), authenticate: { throw Failure.unauthorized }) }
        let value = try plan(authorization())
        #expect(!value.quote.qualifiesMaximumEnvelope)
        #expect(throws: (any Error).self) {
            try GLM5NextResidentRuntime(configuration: fixture.configuration(rank: 0),
                descriptor: fixture.descriptor, resources: value.resources)
        }
        let original = try value.resources.quote(descriptor: fixture.descriptor,
            maximumBufferBytes: Int.max, allocationBound: { $0 })
        #expect(value.quote.loadCapacityBytes == original.peak.reservedBytes)
        #expect(value.quote.requestCapacityBytes == original.request.reservedBytes)
        #expect(throws: (any Error).self) { try plan(authorization(ceiling: value.quote.nativeBytes - 1)) }
        let bytes = try canonicalJSONData(value.resources.workspace)
        #expect(throws: (any Error).self) {
            try GLM5NextResidentResourceEnvelope(descriptor: fixture.descriptor,
                inventory: fixture.artifact.metadata.inventory, rank: 0,
                loadCapacityBytes: 8 << 30, requestCapacityBytes: 8 << 30,
                executionEnvironmentSHA256: environment, workspaceEvidence: bytes,
                authenticateWorkspace: { _ in }, requireExecutionEnvironment: { _ in }, hostAllocationBound: { $0 })
        }
    }

    @Test func finite2048AuthorizationPreservesIdentityAndRefusesEachUpperBoundary() throws {
        let requestID = UUID()
        func make(prompt: Int = 2048, output: Int = 16, chunk: Int = 2048) throws -> GLM5NextCalibration.Authorization {
            try .init(requestID: requestID, nativeHardCapBytes: 8 << 30,
                hostBudgetBytes: 1 << 30, osHeadroomBytes: 1 << 30,
                workspaceNativeAllowanceBytes: 1 << 20, workspaceHostAllowanceBytes: 1 << 20,
                promptTokenIDs: Array(repeating: 1, count: prompt), outputCount: output, chunkSize: chunk)
        }
        let full = try make()
        let decoded = try JSONDecoder().decode(GLM5NextCalibration.Authorization.self,
            from: JSONEncoder().encode(full))
        try decoded.validate()
        #expect(decoded == full && decoded.requestID == requestID)
        #expect(decoded.nativeHardCapBytes == 8 << 30)
        #expect(decoded.hostBudgetBytes == 1 << 30 && decoded.osHeadroomBytes == 1 << 30)
        #expect(decoded.workspaceNativeAllowanceBytes == 1 << 20)
        #expect(decoded.workspaceHostAllowanceBytes == 1 << 20)
        for count in [1, 512, 513, 2048] {
            #expect(try make(prompt: count, chunk: count).promptTokenIDs.count == count)
        }
        for (prompt, output, chunk) in [(2049, 16, 2048), (2048, 17, 2048),
            (2048, 16, 2049), (2047, 16, 2048), (0, 1, 1), (1, 0, 1), (1, 1, 0)] {
            #expect(throws: (any Error).self) { try make(prompt: prompt, output: output, chunk: chunk) }
        }
    }

}
