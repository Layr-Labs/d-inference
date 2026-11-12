import DarkbloomFanProtocol
import Foundation
import ProviderCore

extension Status {
    /// Fan control is opt-in, so a supported Mac that never ran
    /// `sudo darkbloom fan enable` serves hot under macOS automatic control.
    /// One line from the same report as `darkbloom fan status` names that
    /// state, and the command, beside the rest of the summary.
    static func fanControlLine(_ report: FanStatusReport) -> String {
        let label = "Fan control (experimental):"
        let cli = BuildEnvironment.current.cliName
        let details = "(details: \(cli) fan status)"
        if let helper = report.helper {
            return "\(label) \(helper.mode.rawValue) \(details)"
        }
        if report.loaded {
            return "\(label) helper not answering \(details)"
        }
        // `fan disable` leaves the helper installed but not loaded. Say so
        // without advising `enable`, which would reset a configured policy.
        if report.installed {
            return "\(label) installed, helper not running; macOS automatic \(details)"
        }
        if let error = report.diagnostic.error {
            return "\(label) unavailable (\(error))"
        }
        guard report.diagnostic.supported else {
            return "\(label) unsupported on this Mac"
        }
        let hottestGPU = report.diagnostic.gpuTemperatures.map(\.celsius).max()
            .map { String(format: "; GPU %.1f C", $0) } ?? ""
        return "\(label) off, macOS automatic\(hottestGPU). Enable: sudo \(cli) fan enable"
    }
}
