import Foundation

/// Two ordered CPU JSON records. Any encoding/check/write failure poisons the
/// publisher; a retained baseline alone is explicitly not a successful parity run.
final class QwenDenseShortParityOutput {
    enum Record { case baseline, comparison }
    private enum State { case baseline, comparison, writing, complete, failed }
    private var state = State.baseline
    private var totalBytes = 0
    static let recordByteLimit = 32 * 1_048_576, totalByteLimit = 64 * 1_048_576

    func publish<Value: Encodable>(_ value: Value, as record: Record,
        check: () throws -> Void, write: (Data) throws -> Void
    ) throws {
        do {
            guard (state == .baseline && record == .baseline) || (state == .comparison && record == .comparison) else {
                throw ProbeError("Short parity publication is out of order, failed or complete")
            }
            state = .writing
            try check()
            var bytes = try canonicalJSONData(value)
            guard bytes.count < Self.recordByteLimit else { throw ProbeError("Short parity record exceeds 32 MiB") }
            bytes.append(10)
            guard totalBytes <= Self.totalByteLimit - bytes.count else {
                throw ProbeError("Short parity output exceeds 64 MiB")
            }
            try check(); try write(bytes); try check()
            guard state == .writing else { throw ProbeError("Short parity publication was reentered") }
            totalBytes += bytes.count
            state = record == .baseline ? .comparison : .complete
        } catch { state = .failed; throw error }
    }

    func requireComplete() throws {
        guard state == .complete else { state = .failed; throw ProbeError("Short parity did not publish both complete records") }
    }
}
