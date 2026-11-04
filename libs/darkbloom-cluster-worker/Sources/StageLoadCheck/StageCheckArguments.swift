import Foundation

/// `--name value` pairs for a stage-check mode: each allowed name at most once.
enum StageCheckArguments {
    static func parse(_ arguments: [String], allowed: [String]) throws -> [String: String] {
        var fields: [String: String] = [:]
        guard arguments.count % 2 == 0 else { throw StageLoadCheck.Failure("Expected --name value pairs") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard allowed.contains(arguments[index]), fields[arguments[index]] == nil else {
                throw StageLoadCheck.Failure("Unknown or repeated argument \(arguments[index])")
            }
            fields[arguments[index]] = arguments[index + 1]
        }
        return fields
    }
}
