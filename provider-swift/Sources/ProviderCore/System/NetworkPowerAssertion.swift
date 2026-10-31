import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Keeps the macOS network stack alive during sleep so the device can
/// receive APN push notifications (used by MDM for SecurityInfo commands).
///
/// Creates two IOKit power assertions:
/// - `NetworkClientActive`: tells macOS this process needs network during sleep
/// - `BackgroundTask`: enables Power Nap wake cycles for this process
///
/// These assertions do NOT prevent sleep — they just ensure the network
/// stack wakes periodically (every ~15 minutes on AC) to process pushes.
/// No root privileges required.
public final class NetworkPowerAssertion {
    private let reason: String
    private var networkAssertionID: UInt32 = 0
    private var backgroundAssertionID: UInt32 = 0
    private let createAssertion: (String, String) -> UInt32?
    private let destroyAssertion: (UInt32) -> Void

    public convenience init(reason: String = "Darkbloom provider: keep network alive for MDM/APN") {
        self.init(reason: reason, createAssertion: Self.createSystemAssertion,
                  destroyAssertion: Self.destroySystemAssertion)
    }

    init(reason: String, createAssertion: @escaping (String, String) -> UInt32?,
         destroyAssertion: @escaping (UInt32) -> Void) {
        self.reason = reason
        self.createAssertion = createAssertion
        self.destroyAssertion = destroyAssertion
    }

    deinit { release() }

    /// Repeated calls keep successful assertions and retry only failed ones.
    public func acquire() {
        if networkAssertionID == 0 {
            networkAssertionID = createAssertion("NetworkClientActive", reason) ?? 0
        }
        if backgroundAssertionID == 0 {
            backgroundAssertionID = createAssertion("BackgroundTask", reason) ?? 0
        }
    }

    public func release() {
        if networkAssertionID != 0 {
            destroyAssertion(networkAssertionID)
            networkAssertionID = 0
        }
        if backgroundAssertionID != 0 {
            destroyAssertion(backgroundAssertionID)
            backgroundAssertionID = 0
        }
    }

    private static func createSystemAssertion(type: String, reason: String) -> UInt32? {
        #if canImport(IOKit)
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString,
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
