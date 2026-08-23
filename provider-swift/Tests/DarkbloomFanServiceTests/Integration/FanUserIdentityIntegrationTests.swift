import DarkbloomFanService
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let fanServiceIntegrationTestsEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment[
        "DARKBLOOM_FAN_SERVICE_INTEGRATION_TESTS"
    ] else {
        return false
    }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}()

@Suite(
    "Fan user identity (integration)",
    .enabled(
        if: fanServiceIntegrationTestsEnabled,
        "set DARKBLOOM_FAN_SERVICE_INTEGRATION_TESTS=1 to run real dscl tests"))
struct FanUserIdentityIntegrationTests {
    @Test("local account GeneratedUID resolves to a stable UUID through dscl")
    func generatedUIDResolution() throws {
        let uid = UInt32(getuid())
        let first = try FanUserIdentity.generatedUID(for: uid)
        let second = try FanUserIdentity.generatedUID(for: uid)
        #expect(UUID(uuidString: first) != nil)
        #expect(first == second)
    }
}
