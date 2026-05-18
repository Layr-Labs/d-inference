import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Prevents macOS idle sleep while inference work is active. This does not
/// block a user-initiated shutdown/restart, but it keeps long-running jobs from
/// being interrupted by normal idle sleep.
final class InferencePowerAssertion {
    private let reason: String
    private var retainCount = 0

    #if canImport(IOKit)
    private var assertionID: IOPMAssertionID = 0
    #endif

    init(reason: String) {
        self.reason = reason
    }

    deinit {
        releaseSystemAssertion()
    }

    func acquire() {
        retainCount += 1
        guard retainCount == 1 else { return }

        #if canImport(IOKit)
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
        }
        #endif
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        if retainCount == 0 {
            releaseSystemAssertion()
        }
    }

    func releaseAll() {
        retainCount = 0
        releaseSystemAssertion()
    }

    private func releaseSystemAssertion() {
        #if canImport(IOKit)
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        #endif
    }
}
