import Foundation

// Only API stand-ins, for a compile-only Foundation check of the actual facade
// adapter. The C++ ABI and native callback are tested in the frozen shim package.
struct ProbeError: Error { init(_ message: String) {} }
final class JACCLBootstrap {
    typealias Exchange = @Sendable (UUID, Int, Int, UInt64, Data, Int) throws -> Data
    init(membershipEpoch: UUID, rank: Int, exchange: @escaping Exchange) throws {}
}
