// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Decision JSON: strict parse and Python json.dumps")
struct DecisionJSONTests {
    @Test("describe matches the reference for every vector value")
    func describeVectors() throws {
        let vectors = try DecisionReferenceVectors.load()
        let cases = try #require(vectors["describe"]?.array)
        #expect(cases.count == 23)
        for item in cases {
            let value = try #require(item["value"])
            let expected = try #require(item["text"]?.string)
            #expect(value.described == expected)
        }
    }

    @Test("Python float repr: shortest digits with Python's exponent switch", arguments: [
        (1.0, "1.0"), (0.1, "0.1"), (1e16, "1e+16"), (1e15, "1000000000000000.0"),
        (1e-7, "1e-07"), (1e-5, "1e-05"), (0.0001, "0.0001"), (123456789.123, "123456789.123"),
        (-0.0, "-0.0"), (2.5, "2.5"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
        (0.41666666666666663, "0.41666666666666663"), (-12.5, "-12.5"), (9007199254740992.0, "9007199254740992.0"),
    ])
    func pythonFloatRepr(value: Double, expected: String) {
        #expect(DecisionJSON.pythonFloatRepr(value) == expected)
    }

    @Test("member order, int/float spelling and escapes survive a round trip")
    func roundTrip() throws {
        let body = #"{"z": 1, "a": [1.0, -0, 2E3, "x\u00e9\ud83d\ude00\u0001\/"], "n": null, "t": true}"#
        let value = try DecisionJSON.parse(Data(body.utf8))
        #expect(value.members?.map(\.key) == ["z", "a", "n", "t"])
        #expect(value.pythonDumps == "{\"z\": 1, \"a\": [1.0, 0, 2000.0, \"xé😀\\u0001/\"], \"n\": null, \"t\": true}")
        #expect(value.compactJSON == "{\"z\":1,\"a\":[1.0,0,2000.0,\"xé😀\\u0001/\"],\"n\":null,\"t\":true}")
        #expect(try DecisionJSON.parse(Data(value.compactJSON.utf8)) == value)
    }

    @Test("integers keep arbitrary precision")
    func bigIntegers() throws {
        let value = try DecisionJSON.parse(Data("[9223372036854775808, -123456789012345678901234567890]".utf8))
        #expect(value.pythonDumps == "[9223372036854775808, -123456789012345678901234567890]")
    }

    @Test("canonically equivalent keys stay distinct, exact duplicates are refused")
    func keyIdentity() throws {
        let distinct = try DecisionJSON.parse(Data(#"{"é": 1, "e\u0301": 2}"#.utf8))
        #expect(distinct.members?.count == 2)
        #expect(distinct["e\u{301}"] == .integer("2"))
        #expect(throws: DecisionJSONSyntaxError.self) {
            try DecisionJSON.parse(Data(#"{"a": 1, "a": 2}"#.utf8))
        }
    }

    @Test("strict RFC 8259 refusals", arguments: [
        "", " ", "{", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "-", "1e", "NaN", "Infinity",
        "1e400", "[1] [2]", "'a'", "{a:1}", "\"\u{0001}\"", "\"\\x\"", "\"\\ud800\"", "\"\\udc00\"",
        "\"\\ud800\\u0041\"", "tru", "nul", "\u{FEFF}{}",
    ])
    func refusals(body: String) {
        #expect(throws: DecisionJSONSyntaxError.self) { try DecisionJSON.parse(Data(body.utf8)) }
    }

    @Test("invalid UTF-8 and over-deep nesting are refused")
    func invalidBytesAndDepth() {
        #expect(throws: DecisionJSONSyntaxError.self) {
            try DecisionJSON.parse(Data([0x22, 0xC3, 0x28, 0x22]))
        }
        let deep = String(repeating: "[", count: DecisionJSON.maximumDepth + 1)
            + String(repeating: "]", count: DecisionJSON.maximumDepth + 1)
        #expect(throws: DecisionJSONSyntaxError.self) { try DecisionJSON.parse(Data(deep.utf8)) }
        let allowed = String(repeating: "[", count: DecisionJSON.maximumDepth)
            + String(repeating: "]", count: DecisionJSON.maximumDepth)
        #expect((try? DecisionJSON.parse(Data(allowed.utf8))) != nil)
    }

    @Test("Python truthiness drives the reference's `or` defaults")
    func truthiness() {
        let falsy: [DecisionJSON] = [.null, .bool(false), .integer("0"), .float(0), .float(-0.0),
                                      .string(""), .array([]), .object([])]
        #expect(falsy.allSatisfy { !$0.isPythonTruthy })
        let truthy: [DecisionJSON] = [.bool(true), .integer("-1"), .float(0.5), .string(" "),
                                       .array([.null]), .object([.init(key: "k", value: .null)])]
        #expect(truthy.allSatisfy { $0.isPythonTruthy })
    }
}
