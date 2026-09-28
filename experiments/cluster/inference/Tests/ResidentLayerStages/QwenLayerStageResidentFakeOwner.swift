import Foundation

// Fixture-only objects. None is a stand-in accepted by a production loader.
enum ResidentFixtureError: Error, Equatable {
    case injectedForward, injectedClose, injectedLateCheck, retainedRequest, retainedModel
}

final class ResidentFixtureLedger {
    var loads = 0
    var requestConstructions = 0
    var requestRetirements = 0
    var zeroFrontiers = 0
    var modelDeinits = 0
    weak var observedModel: AnyObject?
    weak var observedRequest: AnyObject?
    // Deliberate fault injection, never an API offered by a real private owner.
    var injectedEscapedObject: AnyObject?
}

private final class ResidentFixtureModel {
    let loadID = UUID()
    let originalLoadReceipt = "synthetic-original-load-receipt"
    private let ledger: ResidentFixtureLedger
    init(_ ledger: ResidentFixtureLedger) {
        self.ledger = ledger; ledger.loads += 1
    }
    deinit { ledger.modelDeinits += 1 }
}

private final class ResidentFixtureRequest {
    let identity: QwenLayerStageResidentRequestIdentity
    var frontier = 0
    var rows = [Int]()
    var finalLogits: [Int]?
    private(set) var closed = false
    private let ledger: ResidentFixtureLedger
    init(_ identity: QwenLayerStageResidentRequestIdentity, ledger: ResidentFixtureLedger) {
        self.identity = identity; self.ledger = ledger
        ledger.requestConstructions += 1
        if frontier == 0 && rows.isEmpty && finalLogits == nil { ledger.zeroFrontiers += 1 }
    }
    func retire() {
        if !closed { ledger.requestRetirements += 1 }
        rows.removeAll(); finalLogits = nil; closed = true
    }
}

struct ResidentFixtureResult: Equatable {
    let requestID: UUID
    let modelLoadID: UUID
    let history: [Int]
    let finalFrontier: Int
    let originalLoadReceipt: String
}

enum ResidentFixtureFault: Equatable {
    case none, forwardAfterCommit, close, lateCheck, escapeRequest, escapeModel
}

/// Pure ownership example: creation and model capability stay private, only a
/// fixed CPU result escapes, and each request object leaves its autoreleasepool
/// before the lifecycle's success transition. This is NOT the native owner.
final class ResidentFixtureOwner {
    private var model: ResidentFixtureModel?
    private let lifecycle: QwenLayerStageResidentLifecycle
    private let ledger: ResidentFixtureLedger

    init(maximumRequests: Int, ledger: ResidentFixtureLedger) throws {
        lifecycle = try .init(maximumRequests: maximumRequests)
        self.ledger = ledger
        let created = ResidentFixtureModel(ledger)
        model = created; ledger.observedModel = created
    }

    var snapshot: QwenLayerStageResidentLifecycleSnapshot { lifecycle.snapshot }

    func run(_ identity: QwenLayerStageResidentRequestIdentity, history: [Int],
        fault: ResidentFixtureFault = .none
    ) throws -> ResidentFixtureResult {
        try lifecycle.withRequest(identity: identity) {
            let result = try autoreleasepool { () throws -> ResidentFixtureResult in
                guard let model else { throw ResidentFixtureError.retainedModel }
                let request = ResidentFixtureRequest(identity, ledger: ledger)
                ledger.observedRequest = request
                // The real unchanged request loop owns both success close and
                // cancellation, including errors raised after a native commit.
                defer { if !request.closed { request.retire() } }
                request.rows = history; request.frontier = history.count
                if fault == .forwardAfterCommit { throw ResidentFixtureError.injectedForward }
                request.finalLogits = history
                if fault == .close { throw ResidentFixtureError.injectedClose }
                let result = ResidentFixtureResult(requestID: identity.requestID,
                    modelLoadID: model.loadID, history: history, finalFrontier: request.frontier,
                    originalLoadReceipt: model.originalLoadReceipt)
                request.retire()
                if fault == .escapeRequest { ledger.injectedEscapedObject = request }
                if fault == .escapeModel { ledger.injectedEscapedObject = model }
                return result
            }
            guard ledger.observedRequest == nil else { throw ResidentFixtureError.retainedRequest }
            if fault == .lateCheck { throw ResidentFixtureError.injectedLateCheck }
            return result
        }
    }

    func release() throws {
        try lifecycle.withModelRelease {
            autoreleasepool { model = nil }
            guard ledger.observedModel == nil else { throw ResidentFixtureError.retainedModel }
        }
    }
}
