import Foundation

struct DoctorOptions {
    let storage: URL
    let json: Bool
    let developmentUnsigned: Bool

    init(_ arguments: [String]) throws {
        var seen = Set<String>(), storage = "/", index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw Self.invalid }
            switch option {
            case "--json", "--development-unsigned": index += 1
            case "--storage":
                guard index + 1 < arguments.count else { throw Self.invalid }
                storage = arguments[index + 1]
                guard storage.hasPrefix("/"), storage.utf8.count <= 4096,
                      !storage.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Self.invalid }
                index += 2
            default: throw Self.invalid
            }
        }
        self.storage = URL(fileURLWithPath: storage, isDirectory: true)
        json = seen.contains("--json")
        developmentUnsigned = seen.contains("--development-unsigned")
    }

    private static var invalid: DaemonCLIError { .invalidArguments("doctor") }
}
