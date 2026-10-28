import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// UNRUN pure known-answer vectors; no metadata/helper opt-in, MLX or network.
@Suite struct GLM5NextCalibrationDispatchDigestTests {
    typealias W = GLM5NextCalibrationDispatchWire

    @Test func rawHexPreservesByteOrderLeadingZerosAndHighBits() {
        #expect(W.hex(Data()) == "")
        #expect(W.hex(Data([0, 1, 0x80, 0xff])) == "000180ff")
    }

    @Test func hashMatchesSHA256KnownAnswersWhileHexDoesNotHashAgain() {
        let abc = Data("abc".utf8)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(W.hash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(W.hash(abc) == expected)
        let digest = Data(SHA256.hash(data: abc))
        #expect(W.hex(digest) == expected)
        #expect(W.hash(digest) != expected)
    }
}
