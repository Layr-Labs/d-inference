import Darwin
import Foundation
import XCTest
@testable import ProviderAppAttest

final class WorkerTransportTests: XCTestCase {
    private func pipePair() throws -> (WorkerDescriptor, WorkerDescriptor) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw AppAttestWorkerError.systemFailure }
        let input = WorkerDescriptor(descriptors[0]), output = WorkerDescriptor(descriptors[1])
        try WorkerDescriptor.configure(input.fd); try WorkerDescriptor.configure(output.fd)
        return (input, output)
    }

    func testFrameRoundTripAndExactSizeBound() throws {
        let frame = WorkerFrame(generation: UUID(), sequence: 3, body: .authenticated)
        let encoded = try WorkerFraming.encode(frame)
        XCTAssertNoThrow(try WorkerFraming.encode(frame, limit: encoded.count - 4))
        XCTAssertThrowsError(try WorkerFraming.encode(frame, limit: encoded.count - 5)) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .frameTooLarge)
        }
        let (input, output) = try pipePair()
        try output.write(encoded, deadline: WorkerDeadline(seconds: 1))
        let decoded = try WorkerFraming.read(WorkerFrame.self, from: input, deadline: WorkerDeadline(seconds: 1))
        XCTAssertEqual(decoded.generation, frame.generation)
        XCTAssertEqual(decoded.sequence, 3)
        guard case .authenticated = decoded.body else { return XCTFail("wrong message body") }
    }

    func testOversizedAndEmptyLengthFailWithoutReadingBody() throws {
        let headers: [[UInt8]] = [[0, 0, 0, 0], [0, 1, 0, 1], [255, 255, 255, 255]]
        for header in headers {
            let (input, output) = try pipePair()
            try output.write(Data(header), deadline: WorkerDeadline(seconds: 1))
            XCTAssertThrowsError(try WorkerFraming.read(WorkerFrame.self, from: input, deadline: WorkerDeadline(seconds: 1))) {
                XCTAssertEqual($0 as? AppAttestWorkerError, .frameTooLarge)
            }
        }
    }

    func testFragmentedHeaderCannotRenewAbsoluteDeadline() throws {
        let (input, output) = try pipePair()
        try output.write(Data([0, 0]), deadline: WorkerDeadline(seconds: 1))
        let deadline = WorkerDeadline(seconds: 0.03)
        let started = ContinuousClock.now
        XCTAssertThrowsError(try WorkerFraming.read(WorkerFrame.self, from: input, deadline: deadline)) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .deadlineExceeded)
        }
        XCTAssertLessThan((ContinuousClock.now - started).components.seconds, 1)
        XCTAssertEqual(deadline.remaining, 0)
    }

    func testTruncatedBodyAndUnknownSigningRPCRejected() throws {
        let (input, output) = try pipePair()
        try output.write(Data([0, 0, 0, 10, 123]), deadline: WorkerDeadline(seconds: 1))
        XCTAssertThrowsError(try WorkerFraming.read(WorkerFrame.self, from: input, deadline: WorkerDeadline(seconds: 0.03))) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .deadlineExceeded)
        }
        let arbitrarySign = #"{"generation":"00000000-0000-0000-0000-000000000001","sequence":1,"body":{"sign":{"hash":"anything"}}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(WorkerFrame.self, from: Data(arbitrarySign.utf8)))
    }

    func testGenerationAndSequenceFenceReplays() throws {
        let generation = UUID()
        var order = WorkerExchangeOrder(generation: generation)
        let old = WorkerFrame(generation: generation, sequence: 0, body: .authenticated)
        try order.require(old)
        XCTAssertEqual(try order.next(), 1)
        XCTAssertThrowsError(try order.require(old))
        XCTAssertThrowsError(try order.require(WorkerFrame(generation: UUID(), sequence: 1, body: .authenticated)))
        XCTAssertThrowsError(try order.require(WorkerFrame(generation: generation, sequence: 2, body: .authenticated)))
        XCTAssertNoThrow(try order.require(WorkerFrame(generation: generation, sequence: 1, body: .authenticated)))
    }

    func testQualificationObservationsAreOrderedBoundedAndGenerationFenced() throws {
        var phases = WorkerAssertionEventOrder()
        XCTAssertThrowsError(try phases.accept(.callbackDiscarded))
        try phases.accept(.submitted)
        XCTAssertThrowsError(try phases.accept(.submitted))
        try phases.accept(.callbackDiscarded)
        XCTAssertThrowsError(try phases.accept(.callbackDiscarded))
        let generation = UUID()
        var exchange = WorkerExchangeOrder(generation: generation)
        _ = try exchange.next()
        XCTAssertNoThrow(try exchange.require(WorkerFrame(generation: generation, sequence: 1, body: .assertionQualificationEvent(.submitted))))
        XCTAssertThrowsError(try exchange.require(WorkerFrame(generation: UUID(), sequence: 1, body: .assertionQualificationEvent(.submitted))))
        XCTAssertThrowsError(try exchange.require(WorkerFrame(generation: generation, sequence: 0, body: .assertionQualificationEvent(.callbackDiscarded))))
    }

    func testConcurrentObservationAndReplyWritesCannotInterleaveFrames() throws {
        struct Payload: Codable { let id: Int; let text: String }
        let (input, output) = try pipePair()
        let finished = DispatchGroup()
        let text = String(repeating: "x", count: 24 * 1024)
        for writer in 0..<2 {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do {
                    for index in 0..<8 {
                        try WorkerFraming.send(Payload(id: writer * 8 + index, text: text), to: output,
                                               deadline: WorkerDeadline(seconds: 5))
                    }
                } catch { XCTFail("frame write failed: \(error)") }
            }
        }
        var identifiers = Set<Int>()
        for _ in 0..<16 {
            let frame = try WorkerFraming.read(Payload.self, from: input, deadline: WorkerDeadline(seconds: 5))
            XCTAssertEqual(frame.text, text)
            identifiers.insert(frame.id)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        XCTAssertEqual(identifiers, Set(0..<16))
    }

    func testBootstrapSchemaContainsNoProcessPrivateKey() throws {
        let bootstrap = WorkerBootstrap(version: 1, generation: UUID(), secret: Data(repeating: 4, count: 32),
                                        parentAuditToken: Data(repeating: 1, count: 32), socketPath: "/tmp/isolated/peer",
                                        scope: "https://coordinator.invalid", endpointPublicKey: Data(repeating: 3, count: 32).base64EncodedString(),
                                        qualificationFaultsAllowed: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bootstrap)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "generation", "secret", "parentAuditToken", "socketPath", "scope", "endpointPublicKey", "qualificationFaultsAllowed"])
        XCTAssertEqual(object["endpointPublicKey"] as? String, bootstrap.endpointPublicKey)
        // `secret` is the independent launch nonce, not endpoint key material.
        XCTAssertEqual(object["secret"] as? String, bootstrap.secret.base64EncodedString())
        XCTAssertNotEqual(bootstrap.secret.base64EncodedString(), bootstrap.endpointPublicKey)
    }

    func testQualificationRequiresExactExplicitOptIn() {
        for value in ["", "true", "0", "yes"] {
            XCTAssertFalse(AppAttestWorkerSelection.enabled(in: [AppAttestWorkerSelection.qualificationEnvironment: value]))
        }
        XCTAssertFalse(AppAttestWorkerSelection.enabled(in: [:]))
        XCTAssertTrue(AppAttestWorkerSelection.enabled(in: [AppAttestWorkerSelection.qualificationEnvironment: "1"]))
    }

    func testTypedExchangeRejectsMalformedContext() throws {
        var request = AppAttestShadowPayload(action: "prepare", session: Data(repeating: 1, count: 32).base64EncodedString())
        request.protocolVersion = 3; request.environment = "production"; request.accountScope = String(repeating: "a", count: 64)
        let status = AppAttestStatus(osVersion: "27.0.1", osBuild: "test", appVersion: "test", chip: "test", binaryHash: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try WorkerRequestValidation.validate(request, status: status))
        request.action = "sign"
        XCTAssertThrowsError(try WorkerRequestValidation.validate(request, status: status))
        request.action = "prepare"; request.accountScope = String(repeating: "X", count: 64)
        XCTAssertThrowsError(try WorkerRequestValidation.validate(request, status: status))
        request.accountScope = String(repeating: "a", count: 64); request.proof = "caller-selected-proof"
        XCTAssertThrowsError(try WorkerRequestValidation.validate(request, status: status))
    }
}
