import Foundation
import IOKit.ps

struct QwenResidentBenchmarkWorkerResources: Encodable {
    let os: QwenDenseStageLoadOSObservation
    let powerSource: String
    let lowPowerModeEnabled: Bool
    let thermalState: Int
    let sampledOutsideRequestClock = true
    let wholeProcessMemorySafetyEstablished = false

    /// Sustained benchmark cohorts require actual AC, normal power mode and the
    /// existing direct 6 GiB actual-free / zero-swap / pressure <= 2 admission.
    /// Parent supervision remains responsible for monitoring during native work.
    static func require() throws -> Self {
        guard let unmanaged = IOPSCopyPowerSourcesInfo() else {
            throw ProbeError("Resident benchmark cannot observe its power source")
        }
        let info = unmanaged.takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        guard source == kIOPSACPowerValue, !lowPower,
              thermal == ProcessInfo.ThermalState.nominal.rawValue
                || thermal == ProcessInfo.ThermalState.fair.rawValue else {
            throw ProbeError("Resident benchmark requires AC, normal power mode and nominal/fair thermal state")
        }
        return .init(os: try QwenDenseStageLoadResources.requireInitial(), powerSource: "ac",
            lowPowerModeEnabled: lowPower, thermalState: thermal)
    }
}
