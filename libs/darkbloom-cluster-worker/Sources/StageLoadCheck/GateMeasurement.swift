import DarkbloomClusterRuntime
import Foundation

/// The stage check's own switch for the host memory gate's measurement mode.
/// This tool is a qualification tool and is never the installed path; the mode
/// is still off unless it is asked for by name on the command line.
enum GateMeasurement {
    static let modeArgument = "--qualification-memory-gate"
    static let outputArgument = "--gate-measurement-output"
    static let usage = "\(modeArgument) record keeps every decision of the host memory gate and this Mac's counters "
        + "once a second; measure also leaves a refusal for admissible memory alone unenforced; "
        + "\(outputArgument) /ABS/PATH receives the record"
    nonisolated(unsafe) private static var output: String?

    static func configure(_ fields: [String: String]) throws {
        guard let mode = fields[modeArgument] else {
            guard fields[outputArgument] == nil else {
                throw StageLoadCheck.Failure("\(outputArgument) requires \(modeArgument) record or measure")
            }
            return
        }
        guard let requested = QwenDenseStageLoadMeasurement.Mode(rawValue: mode),
              let path = fields[outputArgument], path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
            throw StageLoadCheck.Failure("\(modeArgument) takes record or measure, with \(outputArgument) naming "
                + "an absolute path that does not exist yet")
        }
        output = path
        try QwenDenseStageLoadMeasurement.shared.enable(requested, permittedBy: .permittedByExplicitFlag)
    }

    /// Writes the record once the run has ended, whether it loaded or failed.
    static func write() {
        guard let output, let report = QwenDenseStageLoadMeasurement.shared.report else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              (try? data.write(to: URL(fileURLWithPath: output), options: [.withoutOverwriting])) != nil else {
            FileHandle.standardError.write(Data("darkbloom-cluster-stage-check: could not write the gate measurement\n".utf8))
            return
        }
    }
}
