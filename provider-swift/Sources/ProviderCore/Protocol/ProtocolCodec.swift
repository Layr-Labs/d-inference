import Foundation

/// Wire codec for provider/coordinator protocol messages.
///
/// Most messages can use the Codable envelopes directly. Register messages with
/// attestation need a small custom path because JSONEncoder cannot emit an
/// already-encoded raw JSON fragment.
public enum ProviderProtocolCodec {
    public static func encodeProviderMessage(_ message: ProviderMessage) throws -> Data {
        if case .register(let register) = message, register.attestation != nil {
            return try encodeRegisterPreservingRawAttestation(register)
        }

        return try makeEncoder().encode(message)
    }

    public static func encodeProviderMessageString(_ message: ProviderMessage) throws -> String {
        let data = try encodeProviderMessage(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProtocolCodecError.nonUTF8Output
        }
        return string
    }

    public static func decodeProviderMessage(from data: Data) throws -> ProviderMessage {
        var message = try JSONDecoder().decode(ProviderMessage.self, from: data)

        if case .register(var register) = message,
           register.attestation != nil,
           let rawAttestation = JSONRawValueExtractor.rawValue(forKey: "attestation", in: data) {
            register.attestation = RawJSON(rawBytes: rawAttestation)
            message = .register(register)
        }

        return message
    }

    public static func decodeProviderMessage(from string: String) throws -> ProviderMessage {
        guard let data = string.data(using: .utf8) else {
            throw ProtocolCodecError.nonUTF8Input
        }
        return try decodeProviderMessage(from: data)
    }

    public static func encodeCoordinatorMessage(_ message: CoordinatorMessage) throws -> Data {
        try makeEncoder().encode(message)
    }

    public static func encodeCoordinatorMessageString(_ message: CoordinatorMessage) throws -> String {
        let data = try encodeCoordinatorMessage(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProtocolCodecError.nonUTF8Output
        }
        return string
    }

    public static func decodeCoordinatorMessage(from data: Data) throws -> CoordinatorMessage {
        try JSONDecoder().decode(CoordinatorMessage.self, from: data)
    }

    public static func decodeCoordinatorMessage(from string: String) throws -> CoordinatorMessage {
        guard let data = string.data(using: .utf8) else {
            throw ProtocolCodecError.nonUTF8Input
        }
        return try decodeCoordinatorMessage(from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func encodeRegisterPreservingRawAttestation(
        _ register: ProviderMessage.Register
    ) throws -> Data {
        var fields: [(String, Data)] = []

        try fields.append(("type", encodeValue("register")))
        try fields.append(("hardware", encodeValue(register.hardware)))
        try fields.append(("models", encodeValue(register.models)))
        try fields.append(("backend", encodeValue(register.backend)))
        try appendIfPresent(register.version, key: "version", to: &fields)
        try appendIfPresent(register.publicKey, key: "public_key", to: &fields)
        if register.encryptedResponseChunks {
            try fields.append(("encrypted_response_chunks", encodeValue(true)))
        }
        try appendIfPresent(register.walletAddress, key: "wallet_address", to: &fields)
        if let attestation = register.attestation {
            try validateRawJSON(attestation.rawBytes)
            fields.append(("attestation", attestation.rawBytes))
        }
        try appendIfPresent(register.prefillTps, key: "prefill_tps", to: &fields)
        try appendIfPresent(register.decodeTps, key: "decode_tps", to: &fields)
        try appendIfPresent(register.authToken, key: "auth_token", to: &fields)
        try appendIfPresent(register.pythonHash, key: "python_hash", to: &fields)
        try appendIfPresent(register.runtimeHash, key: "runtime_hash", to: &fields)
        if !register.templateHashes.isEmpty {
            try fields.append(("template_hashes", encodeValue(register.templateHashes)))
        }
        try appendIfPresent(register.privacyCapabilities, key: "privacy_capabilities", to: &fields)

        return makeObject(fields)
    }

    private static func appendIfPresent<T: Encodable>(
        _ value: T?,
        key: String,
        to fields: inout [(String, Data)]
    ) throws {
        guard let value else { return }
        try fields.append((key, encodeValue(value)))
    }

    private static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    private static func validateRawJSON(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
    }

    private static func makeObject(_ fields: [(String, Data)]) -> Data {
        var data = Data()
        data.appendUTF8("{")

        for (index, field) in fields.enumerated() {
            if index > 0 {
                data.appendUTF8(",")
            }
            data.appendUTF8("\"\(field.0)\":")
            data.append(field.1)
        }

        data.appendUTF8("}")
        return data
    }
}

public enum ProtocolCodecError: Error, Equatable {
    case nonUTF8Input
    case nonUTF8Output
}

private enum JSONRawValueExtractor {
    static func rawValue(forKey targetKey: String, in data: Data) -> Data? {
        var parser = Parser(bytes: [UInt8](data))
        return parser.rawTopLevelValue(forKey: targetKey).map { range in
            data.subdata(in: range)
        }
    }

    private struct Parser {
        private let bytes: [UInt8]
        private var index: Int = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func rawTopLevelValue(forKey targetKey: String) -> Range<Int>? {
            skipWhitespace()
            guard consume(UInt8(ascii: "{")) else { return nil }

            while index < bytes.count {
                skipWhitespace()
                if consume(UInt8(ascii: "}")) {
                    return nil
                }

                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                skipWhitespace()

                let valueStart = index
                guard skipValue() else { return nil }
                let valueEnd = index

                if key == targetKey {
                    return valueStart..<valueEnd
                }

                skipWhitespace()
                if consume(UInt8(ascii: ",")) {
                    continue
                }
                if consume(UInt8(ascii: "}")) {
                    return nil
                }
            }

            return nil
        }

        private mutating func skipValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }

            switch bytes[index] {
            case UInt8(ascii: "{"):
                return skipObject()
            case UInt8(ascii: "["):
                return skipArray()
            case UInt8(ascii: "\""):
                return parseString() != nil
            default:
                return skipPrimitive()
            }
        }

        private mutating func skipObject() -> Bool {
            guard consume(UInt8(ascii: "{")) else { return false }

            while index < bytes.count {
                skipWhitespace()
                if consume(UInt8(ascii: "}")) {
                    return true
                }

                guard parseString() != nil else { return false }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return false }
                skipWhitespace()
                guard skipValue() else { return false }
                skipWhitespace()

                if consume(UInt8(ascii: ",")) {
                    continue
                }
                if consume(UInt8(ascii: "}")) {
                    return true
                }
            }

            return false
        }

        private mutating func skipArray() -> Bool {
            guard consume(UInt8(ascii: "[")) else { return false }

            while index < bytes.count {
                skipWhitespace()
                if consume(UInt8(ascii: "]")) {
                    return true
                }

                guard skipValue() else { return false }
                skipWhitespace()

                if consume(UInt8(ascii: ",")) {
                    continue
                }
                if consume(UInt8(ascii: "]")) {
                    return true
                }
            }

            return false
        }

        private mutating func skipPrimitive() -> Bool {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                    return index > start
                default:
                    index += 1
                }
            }
            return index > start
        }

        private mutating func parseString() -> String? {
            guard consume(UInt8(ascii: "\"")) else { return nil }

            var scalarBytes: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1

                if byte == UInt8(ascii: "\"") {
                    return String(data: Data(scalarBytes), encoding: .utf8)
                }

                if byte == UInt8(ascii: "\\") {
                    guard index < bytes.count else { return nil }
                    scalarBytes.append(byte)
                    scalarBytes.append(bytes[index])
                    index += 1
                    continue
                }

                scalarBytes.append(byte)
            }

            return nil
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                    index += 1
                default:
                    return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else {
                return false
            }
            index += 1
            return true
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
