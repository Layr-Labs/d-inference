import DarkbloomHardwareLoad
import Foundation
import ProviderCore

extension Doctor {
    /// The same document `GET /control/v1/hardware` serves, from a sampler
    /// started for this command only.
    static func hardwareReport() async throws -> String {
        let monitor = HardwareLoadMonitor.live(providerPID: { DesktopHardware.providerPID() })
        let bandwidth = (try? HardwareDetector.detect())?.memoryBandwidthGbs ?? 0
        let report = await DesktopHardware(monitor: monitor)
            .resource(peakBandwidthGbps: bandwidth > 0 ? Double(bandwidth) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}
