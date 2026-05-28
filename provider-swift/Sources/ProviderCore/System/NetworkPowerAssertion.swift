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

    #if canImport(IOKit)
    private var networkAssertionID: IOPMAssertionID = 0
    private var backgroundAssertionID: IOPMAssertionID = 0
    #endif

    private var active = false

    public init(reason: String = "Darkbloom provider: keep network alive for MDM/APN") {
        self.reason = reason
    }

    deinit {
        release()
    }

    /// Acquire both network and background task assertions.
    /// Safe to call multiple times — only the first call creates assertions.
    public func acquire() {
        guard !active else { return }
        active = true

        #if canImport(IOKit)
        // NetworkClientActive: keeps TCP connections alive during sleep,
        // which is critical for APN (courier.push.apple.com:5223).
        var netID = IOPMAssertionID(0)
        let netResult = IOPMAssertionCreateWithName(
            "NetworkClientActive" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &netID
        )
        if netResult == kIOReturnSuccess {
            networkAssertionID = netID
        }

        // BackgroundTask: tells macOS this process has background work,
        // enabling Power Nap wake cycles that process push notifications.
        var bgID = IOPMAssertionID(0)
        let bgResult = IOPMAssertionCreateWithName(
            "BackgroundTask" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &bgID
        )
        if bgResult == kIOReturnSuccess {
            backgroundAssertionID = bgID
        }
        #endif
    }

    /// Release both assertions.
    public func release() {
        guard active else { return }
        active = false

        #if canImport(IOKit)
        if networkAssertionID != 0 {
            IOPMAssertionRelease(networkAssertionID)
            networkAssertionID = 0
        }
        if backgroundAssertionID != 0 {
            IOPMAssertionRelease(backgroundAssertionID)
            backgroundAssertionID = 0
        }
        #endif
    }
}
