import CryptoKit
import Foundation

// Focused CPU mirror check for the provider-swift native-pair public control
// codec and the cluster-member registration negotiation. No MLX, no network,
// no coordinator. Vectors pin the exact Go/Swift/Python public-byte contract
// (darkbloom-platform coordinator/tests/protocol/native_pair_test.go,
//  ProviderCoreTests/Protocol/NativePairMessageTests.swift).

var failures = 0
@MainActor func expect(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("FAIL \(label)") }
}
@MainActor func hex(_ s: String) throws -> Data {
    var data = Data(); var i = s.startIndex
    while i != s.endIndex {
        let next = s.index(i, offsetBy: 2)
        guard let v = UInt8(s[i..<next], radix: 16) else { throw NativePairMessage.Invalid.publicFrame }
        data.append(v); i = next
    }
    return data
}

@MainActor func runChecks() throws {
// 1. Signing bytes match the independent Go/Python fixture.
let hello = try hex("44424e480144424e53016461726b626c6f6f6d2f6e61746976652d617574686f72697a6174696f6e2f636f6d6d6f6e2f7631000102030405060708090a0b0c0d0e0f100000000000000007000000000000000b8ad475855361fdea5e55d4d25a1509a8bd642b6cd46b833911de616f35c259a216ae2c7dc747fc8ce4e9689e4a452ff4521715b2df90080271ccb8fb1cf621af23446f275f5bf8db1c3800edec9b9894e100ab11c066e2da3801b2ee8ec4e858115aeb8857c13d5ecd6019cee9924c70594c1b672a31f77b87794f22db84a7f3e4f23a1c268daffa06314ca0ed8e9750fc8993c955059c388fe2bd927ff669f6185fdc937e1cbcf6020851084ceafbdb4cb5e72b7d4fe7cad2fdd2e69161bc6a0b991f35b02833b15fd09df7db00e02a2f94f79457a156267d94fe7e415bff0e6c652e1114a1a09c419b0a491336f41b5ffbb58187b877c1b702b1945ac6c1680101020000102800001000000000000000004000000000000400000000000000000000000000000000000064000000000000000000000000000000650000000000000000000000000000006607a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")
let message = try NativePairMessage(type: "native_pair_hello", memberNonce: String(repeating: "11", count: 32),
    epoch: String(repeating: "22", count: 16), generation: 7, sequence: 9, payload: hello)
let expected = try hex("49fff06ac2e4b9117f9222129566462a645bcb0541fbb7aa87227c756832af14")
expect(Data(SHA256.hash(data: try message.signingBytes())) == expected, "signing bytes differ from Go/Python fixture")
let encoded = try JSONEncoder().encode(message)
expect(try NativePairMessage.decodePublicFrame(encoded) == message, "strict round trip failed")

// 2. Ambiguous or unknown public records are refused.
let base = #"{"type":"native_pair_hello","version":1,"member_nonce":"1111111111111111111111111111111111111111111111111111111111111111","epoch":"22222222222222222222222222222222","generation":7,"sequence":9,"payload":"AA=="}"#
let cases = [
    String(base.dropLast()) + #", "sequence":9}"#,
    String(base.dropLast()) + #", "secret":"never-admitted"}"#,
    base.replacingOccurrences(of: #""sequence":9"#, with: #""sequence":1.0"#),
    base.replacingOccurrences(of: #""sequence":9"#, with: #""sequence":18446744073709551616"#),
    base.replacingOccurrences(of: #""payload":"AA==""#, with: #""payload":null"#),
    base.replacingOccurrences(of: #""payload":"AA==""#, with: #""payload":"AB==""#),
    base.replacingOccurrences(of: "native_pair_hello", with: "native_pair_unknown"),
    base + base,
]
for (index, value) in cases.enumerated() {
    do {
        _ = try NativePairMessage.decodePublicFrame(Data(value.utf8))
        expect(false, "malformed case \(index) admitted")
    } catch { expect(error is NativePairMessage.Invalid, "case \(index) wrong error") }
}

// 3. Member registration negotiation: one accepted acknowledgment before the
// deadline, bound to this connection's nonce; everything else refused.
var negotiation = ClusterMemberNegotiation()
do {
    try negotiation.accept(ClusterMemberAccepted(executionRole: .clusterMember,
        memberRegistrationNonce: negotiation.nonce, providerID: "provider-a"))
} catch { expect(false, "valid acknowledgment refused: \(error)") }
var duplicate = negotiation
do {
    try duplicate.accept(ClusterMemberAccepted(executionRole: .clusterMember,
        memberRegistrationNonce: duplicate.nonce, providerID: "provider-b"))
    expect(false, "second acknowledgment admitted")
} catch { expect(error is ClusterMemberControlError, "duplicate wrong error") }
var wrongNonce = ClusterMemberNegotiation()
do {
    try wrongNonce.accept(ClusterMemberAccepted(executionRole: .clusterMember,
        memberRegistrationNonce: String(repeating: "0", count: 64), providerID: "provider-a"))
    expect(false, "wrong nonce admitted")
} catch { expect(error is ClusterMemberControlError, "nonce wrong error") }
var soloRole = ClusterMemberNegotiation()
do {
    try soloRole.accept(ClusterMemberAccepted(executionRole: .solo,
        memberRegistrationNonce: soloRole.nonce, providerID: "provider-a"))
    expect(false, "solo role admitted as member")
} catch { expect(error is ClusterMemberControlError, "role wrong error") }
var expired = ClusterMemberNegotiation()
do {
    try expired.accept(ClusterMemberAccepted(executionRole: .clusterMember,
        memberRegistrationNonce: expired.nonce, providerID: "provider-a"),
        now: .now.advanced(by: .seconds(30)))
    expect(false, "expired negotiation admitted")
} catch { expect(error is ClusterMemberControlError, "deadline wrong error") }

}
try runChecks()
if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
print(#"{"passed":true,"groups":3,"modelExecution":false,"networkUsed":false}"#)
