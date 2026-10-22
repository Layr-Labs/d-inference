import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    struct GLMCalibrationCandidates: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "glm-calibration-candidates",
            abstract: "Scan every GLM structural cut against this Mac's current bounds; loads no model.", shouldDisplay: false)
        @Option(help: "Absolute owner-only quotation template; cut may be omitted.")
        var input: String
        @Option(name: .customLong("planner-sha256"), help: "SHA-256 of this installation's darkbloom-cluster-plan helper.")
        var plannerSHA256: String
        @Option(help: "Absolute speed measurement file; may be repeated. Absence means an explicit prior.")
        var speed: [String] = []
        func validate() throws {
            for path in [input] + speed {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("Expected absolute candidate input paths.") }
            }
            guard plannerSHA256.utf8.count == 64, plannerSHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw ValidationError("Expected a lowercase planner SHA-256.") }
        }
        func run() throws {
            let result = try GLM5NextCalibrationPlacement.candidates(input: URL(fileURLWithPath: input),
                measurements: speed.map { URL(fileURLWithPath: $0) }, plannerSHA256: plannerSHA256,
                installedExecutable: URL(fileURLWithPath: Start.currentExecutablePath()))
            try GLM5NextCalibrationQuoteOutput.write(result,
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        }
    }
}
