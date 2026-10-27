import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    struct GLMCalibrationQuote: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "glm-calibration-quote",
            abstract: "Run one bounded private metadata quotation using this installed pair.", shouldDisplay: false)
        @Option(help: "Absolute path to an owner-only bounded quotation selection.")
        var input: String

        func validate() throws {
            guard input.hasPrefix("/"), !input.contains("\0") else {
                throw ValidationError("The quotation input requires an absolute local path.")
            }
        }

        func run() throws {
            // No RuntimeSnapshot, enrollment, update or coordinator connection.
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let response = try GLM5NextCalibrationInstalledQuote.run(input: URL(fileURLWithPath: input),
                installedExecutable: executable)
            try GLM5NextCalibrationQuoteOutput.write(response,
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        }
    }
}
