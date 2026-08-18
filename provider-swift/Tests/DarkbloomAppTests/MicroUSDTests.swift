import Foundation
import Testing
@testable import DarkbloomApp

@Test("Micro-USD formatting is exact and keeps useful fractional precision")
func formatsMicroUSDWithoutFloatingPointMoney() {
    let locale = Locale(identifier: "en_US")

    #expect(MicroUSD.zero.formattedUSD(locale: locale) == "$0.00")
    #expect(MicroUSD(1_000_000).formattedUSD(locale: locale) == "$1.00")
    #expect(MicroUSD(1_200_000).formattedUSD(locale: locale) == "$1.20")
    #expect(MicroUSD(1_234_567).formattedUSD(locale: locale) == "$1.234567")
    #expect(MicroUSD(1).formattedUSD(locale: locale) == "$0.000001")
}

@Test("Micro-USD arithmetic rejects overflow and negative balances")
func validatesMicroUSDArithmetic() throws {
    #expect(try MicroUSD(1_250_000).adding(MicroUSD(750_000)) == MicroUSD(2_000_000))
    #expect(try MicroUSD(2_000_000).subtracting(MicroUSD(750_000)) == MicroUSD(1_250_000))
    #expect(MicroUSD(validating: -1) == nil)

    #expect(throws: MicroUSD.ArithmeticError.insufficientFunds) {
        try MicroUSD(1).subtracting(MicroUSD(2))
    }
    #expect(throws: MicroUSD.ArithmeticError.overflow) {
        try MicroUSD(Int64.max).adding(MicroUSD(1))
    }
}

@Test("Micro-USD serializes as one integer and rejects negative wire values")
func serializesMicroUSDAsInteger() throws {
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(MicroUSD(1_234_567))
    #expect(String(decoding: encoded, as: UTF8.self) == "1234567")
    #expect(try JSONDecoder().decode(MicroUSD.self, from: encoded) == MicroUSD(1_234_567))

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(MicroUSD.self, from: Data("-1".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(MicroUSD.self, from: Data("1.25".utf8))
    }
}
