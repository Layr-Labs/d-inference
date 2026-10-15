import Foundation

struct QwenResidentMTPLoadCleanupError: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: Error
    var description: String { "MTP selected load failed (\(primary)); cleanup failed (\(cleanup))" }
}

/// The body must return CPU values only. Retirement runs after both successful
/// and failed bodies; encoding/publication is unreachable without retirement.
/// It does not manufacture proof from the callbacks: the native owner supplies
/// actual synchronization, weak-owner observations and cache checks.
enum QwenResidentMTPLoadPublication {
    static func run<Value, Output>(body: () throws -> Value,
        retire: () throws -> Void, prepare: (Value) throws -> Output
    ) throws -> Output {
        let result: Result<Value, Error>
        do { result = .success(try body()) }
        catch { result = .failure(error) }
        do { try retire() }
        catch {
            if case .failure(let primary) = result {
                throw QwenResidentMTPLoadCleanupError(primary: primary, cleanup: error)
            }
            throw error
        }
        return try prepare(result.get())
    }
}
