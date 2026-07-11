import Foundation
import Testing

@testable import ProviderCore

@Suite("AppleSMC value codecs")
struct AppleSMCTests {
    @Test("SMC ABI parameter layout remains 80 bytes")
    func parameterLayout() {
        #expect(AppleSMC.parameterSize == 80)
    }

    @Test("four-character keys round trip")
    func keyRoundTrip() {
        let key = SMCKey("F0Tg")
        #expect(key.rawValue == 0x4630_5467)
        #expect(key.name == "F0Tg")
    }

    @Test("Apple Silicon float values are little endian")
    func floatCodec() throws {
        let bits = Float(5_432.5).bitPattern
        let value = SMCValue(
            key: SMCKey("F0Tg"),
            dataType: SMCKey("flt ").rawValue,
            bytes: [
                UInt8(bits & 0xff),
                UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff),
                UInt8((bits >> 24) & 0xff),
            ]
        )
        #expect(value.numeric == 5_432.5)
        #expect(try value.encodeRPM(5_432.5) == value.bytes)
    }

    @Test("legacy fixed-point RPM values remain supported")
    func fixedPointRPMCodec() throws {
        let value = SMCValue(
            key: SMCKey("F0Tg"),
            dataType: SMCKey("fpe2").rawValue,
            bytes: [0x13, 0x88]
        )
        #expect(value.numeric == 1_250)
        #expect(try value.encodeRPM(1_250) == [0x13, 0x88])
    }

    @Test("signed temperature fixed point decodes correctly")
    func temperatureCodec() {
        let value = SMCValue(
            key: SMCKey("TC0P"),
            dataType: SMCKey("sp78").rawValue,
            bytes: [0x2a, 0x80]
        )
        #expect(value.numeric == 42.5)
    }
}
