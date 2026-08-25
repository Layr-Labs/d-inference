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
    private var closed = false

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
            try await sendCommand(payload)
        case .failure(let payload):
            try await send(type: .hostFailure, payload: payload)
        }
    }

    func send<Payload>(
        type: SandboxControlMessageType,
        payload: Payload
    ) async throws where Payload: Codable & Equatable & Sendable {
        guard !closed else {
            throw SandboxHostControlTransportError.disconnected
        }
        let encoded = try encode(
            type: type,
            payload: payload,
            sequence: nextSequence
        )
        guard encoded.count <= SandboxControlCodec.maximumFrameBytes else {
            throw SandboxHostControlTransportError.frameTooLarge
        }
        try await enqueue(encoded)
    }

    private func sendCommand(
        _ payload: SandboxWireCommandStatus
    ) async throws {
        guard !closed else {
            throw SandboxHostControlTransportError.disconnected
        }
        var encoded = try encode(
            type: SandboxControlMessageType.commandState,
            payload: payload,
            sequence: nextSequence
        )
        if encoded.count > SandboxControlCodec.maximumFrameBytes {
            let fitted = try fitCommandStatus(payload)
            encoded = fitted.encoded
        }
        try await enqueue(encoded)
    }

    private func encode<Payload>(
        type: SandboxControlMessageType,
        payload: Payload,
        sequence: UInt64
    ) throws -> Data where Payload: Codable & Equatable & Sendable {
        let envelope = SandboxControlEnvelope(
            type: type,
            hostID: hostID,
            connectionEpoch: connectionEpoch,
            sequence: sequence,
            payload: payload
        )
        return try encoder.encode(envelope)
    }

    private func enqueue(_ encoded: Data) async throws {
        guard encoded.count <= SandboxControlCodec.maximumFrameBytes else {
            throw SandboxHostControlTransportError.frameTooLarge
        }
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

    private func fitCommandStatus(
        _ payload: SandboxWireCommandStatus
    ) throws -> (status: SandboxWireCommandStatus, encoded: Data) {
        let standardOutput = Array((payload.standardOutput ?? "").utf8)
        let standardError = Array((payload.standardError ?? "").utf8)
        var lowerBound = 0
        var upperBound = standardOutput.count + standardError.count
        var best: (status: SandboxWireCommandStatus, encoded: Data)?

        while lowerBound <= upperBound {
            let budget = lowerBound + (upperBound - lowerBound) / 2
            let limits = Self.streamLimits(
                budget: budget,
                standardOutputBytes: standardOutput.count,
                standardErrorBytes: standardError.count
            )
            let candidate = SandboxWireCommandStatus(
                commandID: payload.commandID,
                scope: payload.scope,
                state: payload.state,
                exitCode: payload.exitCode,
                standardOutput: Self.prefix(
                    payload.standardOutput,
                    utf8Bytes: standardOutput,
                    limit: limits.standardOutput
                ),
                standardError: Self.prefix(
                    payload.standardError,
                    utf8Bytes: standardError,
                    limit: limits.standardError
                ),
                outputTruncated: payload.outputTruncated
                    || limits.standardOutput < standardOutput.count
                    || limits.standardError < standardError.count,
                errorCode: payload.errorCode
            )
            let encoded = try encode(
                type: SandboxControlMessageType.commandState,
                payload: candidate,
                sequence: nextSequence
            )
            if encoded.count <= SandboxControlCodec.maximumFrameBytes {
                best = (status: candidate, encoded: encoded)
                lowerBound = budget + 1
            } else {
                upperBound = budget - 1
            }
        }
        guard let best else {
            throw SandboxHostControlTransportError.frameTooLarge
        }
        return best
    }

    private static func streamLimits(
        budget: Int,
        standardOutputBytes: Int,
        standardErrorBytes: Int
    ) -> (standardOutput: Int, standardError: Int) {
        var output = min(standardOutputBytes, (budget + 1) / 2)
        var error = min(standardErrorBytes, budget / 2)
        var remaining = budget - output - error
        let additionalOutput = min(
            remaining,
            standardOutputBytes - output
        )
        output += additionalOutput
        remaining -= additionalOutput
        error += min(remaining, standardErrorBytes - error)
        return (output, error)
    }

    private static func prefix(
        _ original: String?,
        utf8Bytes: [UInt8],
        limit: Int
    ) -> String? {
        guard let original else {
            return nil
        }
        guard utf8Bytes.count > limit else {
            return original
        }
        var validLimit = min(limit, utf8Bytes.count)
        while validLimit > 0,
              String(bytes: utf8Bytes.prefix(validLimit), encoding: .utf8) == nil
        {
            validLimit -= 1
        }
        return String(
            decoding: utf8Bytes.prefix(validLimit),
            as: UTF8.self
        )
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        pending?.task.cancel()
        pending = nil
        await transport.close()
    }

    package func nextSequenceForTesting() -> UInt64 {
        nextSequence
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
