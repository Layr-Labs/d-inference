import Foundation

/// Named checks. A refusal passes only when the body throws an error whose
/// text names the expected reason, so an input refused for some other reason
/// (or by some other guard) fails the check that names it. A failed check is
/// recorded and the run continues, so one run reports every check that fails.
final class StageTransferChecks {
    private(set) var accepted: [String] = []
    private(set) var refused: [String] = []
    private(set) var failures: [String] = []

    func require(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        do {
            if try value() { accepted.append(name) } else { failures.append("Check failed: " + name) }
        } catch { failures.append("Check failed: \(name): \(error)") }
    }

    func refuses(_ name: String, because reason: String, _ body: () throws -> Void) throws {
        do { try body() } catch {
            if String(describing: error).contains(reason) { refused.append(name) }
            else { failures.append("Check refused for another reason: \(name): \(error)") }
            return
        }
        failures.append("Check accepted: " + name)
    }
}

/// Retained registered metadata (names, shapes, dtypes and byte counts only).
struct RetainedQwenInputs: Decodable {
    struct Profile: Decodable {
        let configuration: Data
        let canonicalTensors: [QwenDenseCanonicalTensor]
    }
    let nine: Profile
    let twentySeven: Profile

    init(file: URL) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
}
