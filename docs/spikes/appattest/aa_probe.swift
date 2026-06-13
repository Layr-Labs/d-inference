// App Attest feasibility probe (issue #328). Runs anywhere; the decisive
// signal is `isSupported` (true only on macOS 27+ with Full Security + SIP).
// Build:  swiftc aa_probe.swift -o aa_probe
// Run:    ./aa_probe
import Foundation
import DeviceCheck

let v = ProcessInfo.processInfo.operatingSystemVersion
print("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
let svc = DCAppAttestService.shared
print("DCAppAttestService.isSupported = \(svc.isSupported)")
guard svc.isSupported else {
    print("RESULT: App Attest UNAVAILABLE on this OS — spike cannot proceed here (need macOS 27).")
    exit(0)
}
print("RESULT: App Attest available — proceed to aa_attest (the real validation).")
