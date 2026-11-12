import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// RED STUB (test-only commit): the API the tests need, with the behavior the release has today: nothing restarts a
/// cluster service left on an earlier release by an update. The next commit implements it.
public enum ClusterServiceStaleRestart {
    public struct Asked: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var supervisorPID: Int32
        public var at: Double

        public init(from: String, to: String, supervisorPID: Int32, at: Double) {
            self.from = from; self.to = to; self.supervisorPID = supervisorPID; self.at = at
        }
    }

    public enum Decision: Equatable, Sendable {
        case nothing
        case restart(from: String, to: String)
    }

    public static let fileName = "service-restart-asked.json"
    public static let onceEverySeconds: Double = 6 * 3600

    public static func decide(thisVersion: String, parentPID: Int32, supervisor: ClusterMemberSupervisorState?,
                              jobPID: Int32?, asked: Asked?, now: Double) -> Decision {
        .nothing
    }

    static func restartIfStale(environment: [String: String], executablePath: String, thisVersion: String,
                               parentPID: Int32, now: Double,
                               printJob: (String) -> LaunchctlControl.Output = { LaunchctlControl.printOutput(label: $0) },
                               kick: (String, @escaping @Sendable (String) -> Void) -> Void = { _, _ in },
                               say: @escaping @Sendable (String) -> Void) -> Decision {
        .nothing
    }

    static func jobPID(launchctlPrint output: String) -> Int32? {
        guard let expression = try? NSRegularExpression(pattern: #"(?m)^\s*pid\s*=\s*([1-9][0-9]*)\s*$"#),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int32(output[range])
    }
}
