import Foundation

/// Named checks. A refusal passes only when the body throws an error whose
/// text names the expected reason, so an input refused for some other reason
/// (or by some other guard) fails the check that names it.
final class StageTransferChecks {
    private(set) var accepted: [String] = []
    private(set) var refused: [String] = []

    func require(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { throw ProbeError("Check failed: " + name) }
        accepted.append(name)
    }

    func refuses(_ name: String, because reason: String, _ body: () throws -> Void) throws {
        do { try body() } catch {
            guard String(describing: error).contains(reason) else {
                throw ProbeError("Check refused for another reason: \(name): \(error)")
            }
            refused.append(name)
            return
        }
        throw ProbeError("Check accepted: " + name)
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
