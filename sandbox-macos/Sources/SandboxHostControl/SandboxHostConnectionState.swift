import Foundation
import SandboxCore

actor SandboxHostOutboundWriter {
    private struct PendingWrite {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let transport: any SandboxHostControlTransport
    private let hostID: UUID
    private let connectionEpoch: UUID
    private let encoder: JSONEncoder
    private var nextSequence: UInt64 = 1
    private var pending: PendingWrite?

    init(
        transport: any SandboxHostControlTransport,
        hostID: UUID,
        connectionEpoch: UUID
    ) {
        self.transport = transport
        self.hostID = hostID
        self.connectionEpoch = connectionEpoch
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func send(_ response: SandboxHostControlResponse) async throws {
        switch response {
        case .none:
            return
        case .operation(let payload):
            try await send(type: .operationState, payload: payload)
        case .command(let payload):
            try await send(type: .commandState, payload: payload)
        case .failure(let payload):
            try await send(type: .hostFailure, payload: payload)
        }
    }

    func send<Payload>(
        type: SandboxControlMessageType,
        payload: Payload
    ) async throws where Payload: Codable & Equatable & Sendable {
        let envelope = SandboxControlEnvelope(
            type: type,
            hostID: hostID,
            connectionEpoch: connectionEpoch,
            sequence: nextSequence,
            payload: payload
        )
        let encoded = try encoder.encode(envelope)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw SandboxHostControlTransportError.invalidTextFrame
        }
        nextSequence += 1

        let previous = pending?.task
        let id = UUID()
        let task = Task {
            if let previous {
                try await previous.value
            }
            try Task.checkCancellation()
            try await transport.send(text: text)
        }
        pending = PendingWrite(id: id, task: task)
        do {
            try await task.value
            if pending?.id == id {
                pending = nil
            }
        } catch {
            if pending?.id == id {
                pending = nil
            }
            throw error
        }
    }

    func close() async {
        pending?.task.cancel()
        pending = nil
        await transport.close()
    }
}

actor SandboxHostInboundAuthority {
    private let hostID: UUID
    private let connectionEpoch: UUID
    private var lastSequence: UInt64 = 0

    init(hostID: UUID, connectionEpoch: UUID) {
        self.hostID = hostID
        self.connectionEpoch = connectionEpoch
    }

    func accept(_ message: SandboxCoordinatorControlMessage) throws {
        let identity = message.envelopeIdentity
        guard identity.hostID == hostID,
              identity.connectionEpoch == connectionEpoch
        else {
            throw SandboxHostControlTransportError.sessionMismatch
        }
        guard identity.sequence > lastSequence else {
            throw SandboxHostControlTransportError.sequenceReplay
        }
        lastSequence = identity.sequence
    }
}

actor SandboxHostHandlerWorkSet {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func submit(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let id = UUID()
        let task = Task {
            await operation()
            self.finished(id)
        }
        tasks[id] = task
    }

    func cancelAll() {
        let active = tasks.values
        tasks.removeAll(keepingCapacity: false)
        for task in active {
            task.cancel()
        }
    }

    private func finished(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }
}

private struct SandboxControlEnvelopeIdentity: Sendable {
    let hostID: UUID
    let connectionEpoch: UUID
    let sequence: UInt64
}

private extension SandboxCoordinatorControlMessage {
    var envelopeIdentity: SandboxControlEnvelopeIdentity {
        switch self {
        case .prepare(let envelope):
            makeIdentity(envelope)
        case .leaseRenew(let envelope):
            makeIdentity(envelope)
        case .command(let envelope):
            makeIdentity(envelope)
        case .cancelCommand(let envelope):
            makeIdentity(envelope)
        case .stop(let envelope):
            makeIdentity(envelope)
        case .delete(let envelope):
            makeIdentity(envelope)
        case .drain(let envelope):
            makeIdentity(envelope)
        }
    }

    private func makeIdentity<Payload>(
        _ envelope: SandboxControlEnvelope<Payload>
    ) -> SandboxControlEnvelopeIdentity
    where Payload: Codable & Equatable & Sendable {
        SandboxControlEnvelopeIdentity(
            hostID: envelope.hostID,
            connectionEpoch: envelope.connectionEpoch,
            sequence: envelope.sequence
        )
    }
}
