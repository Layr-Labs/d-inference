import Foundation
import Testing

@testable import DarkbloomFanCore

@Suite("SMC value codecs")
struct SMCCodecTests {
    @Test("AppleSMC parameter ABI remains exactly 80 bytes")
    func abiLayout() {
        #expect(AppleSMCBackend.abiStride == AppleSMCBackend.expectedABISize)
        #expect(AppleSMCBackend.expectedABISize == 80)
        #expect(AppleSMCBackend.abiOffsets == [
            "key": 0,
            "version": 4,
            "pLimitData": 12,
            "keyInfo": 28,
            "result": 40,
            "status": 41,
            "data8": 42,
            "data32": 44,
            "bytes": 48,
        ])
    }

    @Test("SMC keys require four printable ASCII bytes")
    func keyValidation() throws {
        let valid = "F0Tg"
        let key = try SMCKey(valid)
        #expect(key.rawValue == "F0Tg")
        #expect(SMCKey(code: key.code) == key)

        let tooShort = "F0"
        #expect(throws: SMCError.invalidKey("F0")) {
            _ = try SMCKey(tooShort)
        }
        let nonPrintable = "F0\nX"
        #expect(throws: SMCError.invalidKey("F0\nX")) {
            _ = try SMCKey(nonPrintable)
        }
    }

    @Test("decoded SMC keys and types cannot bypass four-byte validation")
    func codableValidation() throws {
        let decoder = JSONDecoder()
        let key = try decoder.decode(
            SMCKey.self,
            from: Data(#"{"rawValue":"F0Tg"}"#.utf8)
        )
        #expect(key == "F0Tg")
        #expect(throws: SMCError.invalidKey("F0")) {
            _ = try decoder.decode(
                SMCKey.self,
                from: Data(#"{"rawValue":"F0"}"#.utf8)
            )
        }
        #expect(throws: SMCError.invalidDataType("flt")) {
            _ = try decoder.decode(
                SMCDataType.self,
                from: Data(#"{"rawValue":"flt"}"#.utf8)
            )
        }
    }

    @Test("little-endian flt values round trip")
    func floatRoundTrip() throws {
        let key: SMCKey = "F0Tg"
        let info = SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt "))
        let bytes = try SMCValue.float32Bytes(4_621.5, key: key)
        #expect(bytes == [0x00, 0x6c, 0x90, 0x45])
        let value = try SMCValue(key: key, info: info, bytes: bytes)
        #expect(abs(try value.float32() - 4_621.5) < 0.001)
        #expect(abs(try value.number() - 4_621.5) < 0.001)
    }

    @Test("ui8 and fixed-point read codecs are big-endian where required")
    func integerAndFixedPointCodecs() throws {
        let count = try SMCValue(
            key: "FNum",
            info: SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 ")),
            bytes: [2]
        )
        #expect(try count.uint8() == 2)
        #expect(try count.number() == 2)

        let fpe2 = try SMCValue(
            key: "F0Ac",
            info: SMCKeyInfo(dataSize: 2, dataType: try SMCDataType("fpe2")),
            bytes: [0x3e, 0x80]
        )
        #expect(try fpe2.number() == 4_000)

        let sp78 = try SMCValue(
            key: "TG0D",
            info: SMCKeyInfo(dataSize: 2, dataType: try SMCDataType("sp78")),
            bytes: [0x2d, 0x80]
        )
        #expect(try sp78.number() == 45.5)

        let sp1e = try SMCValue(
            key: "TEST",
            info: SMCKeyInfo(dataSize: 2, dataType: try SMCDataType("sp1e")),
            bytes: [0x60, 0x00]
        )
        #expect(try sp1e.number() == 1.5)
    }

    @Test("type and length mismatches fail closed")
    func mismatches() throws {
        let key: SMCKey = "F0Tg"
        #expect(throws: SMCError.dataLengthMismatch(key: key, expected: 4, actual: 1)) {
            _ = try SMCValue(
                key: key,
                info: SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt ")),
                bytes: [0]
            )
        }

        let value = try SMCValue(
            key: key,
            info: SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 ")),
            bytes: [1]
        )
        #expect(throws: SMCError.typeMismatch(key: key, expected: "flt ", actual: "ui8 ")) {
            _ = try value.float32()
        }
    }
}
