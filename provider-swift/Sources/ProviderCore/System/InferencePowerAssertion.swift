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
    private var assertionID: UInt32 = 0
    private let createAssertion: (String) -> UInt32?
    private let destroyAssertion: (UInt32) -> Void

    init(reason: String, createAssertion: ((String) -> UInt32?)? = nil,
         destroyAssertion: ((UInt32) -> Void)? = nil) {
        self.reason = reason
        self.createAssertion = createAssertion ?? Self.createSystemAssertion
        self.destroyAssertion = destroyAssertion ?? Self.destroySystemAssertion
    }

    deinit { releaseSystemAssertion() }

    func acquire() {
        retainCount += 1
        _ = ensureAcquired()
    }

    /// Retry a failed system acquisition without retaining another owner.
    @discardableResult
    func ensureAcquired() -> Bool {
        guard retainCount > 0 else { return false }
        if assertionID == 0 { assertionID = createAssertion(reason) ?? 0 }
        return assertionID != 0
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        if retainCount == 0 { releaseSystemAssertion() }
    }

    func releaseAll() {
        retainCount = 0
        releaseSystemAssertion()
    }

    private func releaseSystemAssertion() {
        guard assertionID != 0 else { return }
        destroyAssertion(assertionID)
        assertionID = 0
    }

    private static func createSystemAssertion(reason: String) -> UInt32? {
        #if canImport(IOKit)
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
        #else
        return nil
        #endif
    }

    private static func destroySystemAssertion(_ id: UInt32) {
        #if canImport(IOKit)
        IOPMAssertionRelease(id)
        #endif
    }
}
