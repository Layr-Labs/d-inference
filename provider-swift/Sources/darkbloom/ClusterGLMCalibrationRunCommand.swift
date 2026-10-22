import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    struct GLMCalibrationRun: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "glm-calibration-run",
            abstract: "Run one explicit private finite calibration with the installed paired Mac.", shouldDisplay: false)
        @Option(help: "Absolute path to the owner-only canonical dispatch selection on this Mac.")
        var input: String
        @Option(name: .customLong("placement"), help: "One current candidate snapshot per rank; repeat twice to choose the cut automatically from the same pair of snapshots on both Macs.")
        var placement: [String] = []
        func validate() throws {
            guard placement.isEmpty || placement.count == 2 else { throw ValidationError("Automatic selection requires both rank snapshots.") }
            for path in placement {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("Expected absolute placement snapshot paths.") }
            }
            guard input.hasPrefix("/"), !input.contains("\0") else { throw ValidationError("Expected an absolute local finite selection.") }
        }
        func run() throws {
            let result = try GLM5NextCalibrationInstalledDispatch.run(input: URL(fileURLWithPath: input),
                installedExecutable: URL(fileURLWithPath: Start.currentExecutablePath()),
                placementSnapshots: placement.map { URL(fileURLWithPath: $0) })
            try GLM5NextCalibrationQuoteOutput.write(result,
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
            let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            guard object?["success"] as? Bool == true else { throw ExitCode.failure }
        }
    }
}
