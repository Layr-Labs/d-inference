import Foundation

public enum SandboxControlCodecError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidFrame
    case duplicateKey(String)
    case unknownOrMissingFields
    case unsupportedMessageType(String)
    case unsupportedProtocolVersion(UInt16)
    case invalidSequence
    case invalidPayload

    public var description: String {
        switch self {
        case .invalidFrame:
            return "sandbox control frame is malformed"
        case .duplicateKey(let key):
            return "sandbox control frame repeats JSON key \(key)"
        case .unknownOrMissingFields:
            return "sandbox control frame fields do not match the protocol"
        case .unsupportedMessageType(let type):
            return "unsupported sandbox control message type \(type)"
        case .unsupportedProtocolVersion(let version):
            return "unsupported sandbox control protocol version \(version)"
        case .invalidSequence:
            return "sandbox control sequence must be greater than zero"
        case .invalidPayload:
            return "sandbox control payload violates the protocol"
        }
    }
}

public enum SandboxCoordinatorControlMessage: Equatable, Sendable {
    case prepare(SandboxControlEnvelope<SandboxWirePrepare>)
    case leaseRenew(SandboxControlEnvelope<SandboxWireLeaseRenew>)
    case command(SandboxControlEnvelope<SandboxWireCommand>)
    case cancelCommand(SandboxControlEnvelope<SandboxWireCommandControl>)
    case stop(SandboxControlEnvelope<SandboxWireOperation>)
    case delete(SandboxControlEnvelope<SandboxWireOperation>)
    case drain(SandboxControlEnvelope<SandboxWireDrain>)
}

public enum SandboxControlCodec {
    public static let maximumFrameBytes = 2 * 1_024 * 1_024

    public static func decodeCoordinatorMessage(
        _ data: Data
    ) throws -> SandboxCoordinatorControlMessage {
        guard !data.isEmpty, data.count <= maximumFrameBytes else {
            throw SandboxControlCodecError.invalidFrame
        }
        do {
            try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        } catch SandboxJSONIntegrityError.duplicateKey(let key) {
            throw SandboxControlCodecError.duplicateKey(key)
        } catch {
            throw SandboxControlCodecError.invalidFrame
        }

        let root: [String: Any]
        do {
            root = try requireObject(
                JSONSerialization.jsonObject(with: data)
            )
        } catch {
            throw SandboxControlCodecError.invalidFrame
        }
        try requireFields(
            root,
            required: [
                "type",
                "protocol_version",
                "host_id",
                "connection_epoch",
                "sequence",
                "payload",
            ]
        )
        guard let typeName = root["type"] as? String,
              let messageType = SandboxControlMessageType(rawValue: typeName),
              let payload = root["payload"] as? [String: Any]
        else {
            if let typeName = root["type"] as? String {
                throw SandboxControlCodecError.unsupportedMessageType(typeName)
            }
            throw SandboxControlCodecError.invalidFrame
        }

        switch messageType {
        case .prepare:
            try requireFields(
                payload,
                required: [
                    "operation_id",
                    "scope",
                    "resources",
                    "base_image_id",
                    "lease_expires_at",
                ]
            )
            try requireScopeFields(payload)
            try requireResourceFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWirePrepare> =
                try decode(data, expectedType: .prepare)
            guard validate(envelope.payload) else {
                throw SandboxControlCodecError.invalidPayload
            }
            return .prepare(envelope)
        case .leaseRenew:
            try requireFields(
                payload,
                required: ["operation_id", "scope", "lease_expires_at"]
            )
            try requireScopeFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWireLeaseRenew> =
                try decode(data, expectedType: .leaseRenew)
            guard validate(envelope.payload) else {
                throw SandboxControlCodecError.invalidPayload
            }
            return .leaseRenew(envelope)
        case .command:
            try requireFields(
                payload,
                required: [
                    "command_id",
                    "idempotency_key",
                    "scope",
                    "arguments",
                    "timeout_seconds",
                ],
                optional: ["environment", "working_directory"]
            )
            try requireScopeFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWireCommand> =
                try decode(data, expectedType: .command)
            guard validate(envelope.payload) else {
                throw SandboxControlCodecError.invalidPayload
            }
            return .command(envelope)
        case .cancelCommand:
            try requireFields(
                payload,
                required: ["operation_id", "command_id", "scope"]
            )
            try requireScopeFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWireCommandControl> =
                try decode(data, expectedType: .cancelCommand)
            return .cancelCommand(envelope)
        case .stop:
            try requireFields(
                payload,
                required: ["operation_id", "scope"]
            )
            try requireScopeFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWireOperation> =
                try decode(data, expectedType: .stop)
            return .stop(envelope)
        case .delete:
            try requireFields(
                payload,
                required: ["operation_id", "scope"]
            )
            try requireScopeFields(payload)
            let envelope: SandboxControlEnvelope<SandboxWireOperation> =
                try decode(data, expectedType: .delete)
            return .delete(envelope)
        case .drain:
            try requireFields(
                payload,
                required: ["operation_id", "reason"]
            )
            let envelope: SandboxControlEnvelope<SandboxWireDrain> =
                try decode(data, expectedType: .drain)
            guard !envelope.payload.reason.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  envelope.payload.reason.utf8.count <= 256
            else {
                throw SandboxControlCodecError.invalidPayload
            }
            return .drain(envelope)
        case .hostRegister,
             .hostHeartbeat,
             .operationState,
             .commandState,
             .hostFailure:
            throw SandboxControlCodecError.unsupportedMessageType(typeName)
        }
    }

    private static func decode<Payload>(
        _ data: Data,
        expectedType: SandboxControlMessageType
    ) throws -> SandboxControlEnvelope<Payload>
    where Payload: Codable & Equatable & Sendable {
        let envelope: SandboxControlEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(
                SandboxControlEnvelope<Payload>.self,
                from: data
            )
        } catch {
            throw SandboxControlCodecError.invalidFrame
        }
        guard envelope.type == expectedType else {
            throw SandboxControlCodecError.unsupportedMessageType(
                envelope.type.rawValue
            )
        }
        guard envelope.protocolVersion == sandboxControlProtocolVersion else {
            throw SandboxControlCodecError.unsupportedProtocolVersion(
                envelope.protocolVersion
            )
        }
        guard envelope.sequence > 0 else {
            throw SandboxControlCodecError.invalidSequence
        }
        return envelope
    }

    private static func validate(_ payload: SandboxWirePrepare) -> Bool {
        validIdentifier(payload.baseImageID)
            && validResources(payload.resources)
            && validTimestamp(payload.leaseExpiresAt)
    }

    private static func validate(_ payload: SandboxWireLeaseRenew) -> Bool {
        validTimestamp(payload.leaseExpiresAt)
    }

    private static func validate(_ payload: SandboxWireCommand) -> Bool {
        guard validIdentifier(payload.idempotencyKey),
              (1...256).contains(payload.arguments.count),
              (1...900).contains(payload.timeoutSeconds),
              (payload.environment?.count ?? 0) <= 128,
              payload.environment?.isEmpty != true
        else {
            return false
        }
        var totalBytes = 0
        for argument in payload.arguments {
            guard !argument.contains("\0") else {
                return false
            }
            totalBytes += argument.utf8.count
        }
        for (key, value) in payload.environment ?? [:] {
            guard validEnvironmentKey(key),
                  !value.contains("\0")
            else {
                return false
            }
            totalBytes += key.utf8.count + value.utf8.count
        }
        if let workingDirectory = payload.workingDirectory {
            guard workingDirectory.hasPrefix("/"),
                  !workingDirectory.contains("\0"),
                  (workingDirectory as NSString).standardizingPath
                    == workingDirectory
            else {
                return false
            }
            totalBytes += workingDirectory.utf8.count
        }
        return totalBytes <= 1_024 * 1_024
    }

    private static func validResources(
        _ resources: SandboxWireResources
    ) -> Bool {
        let gibibyte = SandboxResourcePolicy.gibibyte
        return (1...64).contains(resources.cpuCount)
            && ((2 * gibibyte)...(512 * gibibyte)).contains(
                resources.memoryBytes
            )
            && (
                resources.workspaceBytes == 25 * gibibyte
                    || resources.workspaceBytes == 50 * gibibyte
            )
            && (1...900).contains(resources.commandTimeoutSeconds)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIIAlphanumeric(first)
        else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d
        }
    }

    private static func validEnvironmentKey(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIIAlpha(first) || first == 0x5f
        else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 0x5f
        }
    }

    private static func isASCIIAlpha(_ value: UInt8) -> Bool {
        (0x41...0x5a).contains(value) || (0x61...0x7a).contains(value)
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        isASCIIAlpha(value) || (0x30...0x39).contains(value)
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if formatter.date(from: value) != nil {
            return true
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func requireObject(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw SandboxControlCodecError.invalidFrame
        }
        return object
    }

    private static func requireFields(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
              keys.isSubset(of: required.union(optional))
        else {
            throw SandboxControlCodecError.unknownOrMissingFields
        }
        guard keys.allSatisfy({ !(object[$0] is NSNull) }) else {
            throw SandboxControlCodecError.invalidPayload
        }
    }

    private static func requireScopeFields(
        _ payload: [String: Any]
    ) throws {
        try requireFields(
            requireObject(payload["scope"] as Any),
            required: ["sandbox_id", "generation", "fencing_token"]
        )
    }

    private static func requireResourceFields(
        _ payload: [String: Any]
    ) throws {
        try requireFields(
            requireObject(payload["resources"] as Any),
            required: [
                "cpu_count",
                "memory_bytes",
                "workspace_bytes",
                "command_timeout_seconds",
                "gpu",
            ]
        )
    }
}
