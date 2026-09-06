import CryptoKit
import Darwin
import Foundation

enum ReplayFailure: Error { case invalidInput(String) }

func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw ReplayFailure.invalidInput(reason) }
}

func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func readBounded(_ url: URL, limit: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try require(descriptor >= 0, "cannot open regular input")
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    try require(fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
        && status.st_size > 0 && status.st_size <= limit, "input length or file type")
    let bytes = try handle.read(upToCount: limit + 1) ?? Data()
    try require(bytes.count == status.st_size && bytes.count <= limit, "input changed or exceeded bound")
    return bytes
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(value)
    try bytes.write(to: url, options: .withoutOverwriting)
}

struct ReplayOptions {
    let input: URL
    let inputSHA256: String
    let output: URL
    let arm: String

    init(_ args: [String]) throws {
        try require(args.count == 8, "four explicit paired replay options required")
        var values = [String: String]()
        for index in stride(from: 0, to: args.count, by: 2) {
            let key = args[index]
            try require(["--input", "--input-sha256", "--output", "--arm"].contains(key)
                && values[key] == nil, "unknown or duplicate replay option")
            values[key] = args[index + 1]
        }
        guard let input = values["--input"], let output = values["--output"],
            let hash = values["--input-sha256"], let arm = values["--arm"] else {
            throw ReplayFailure.invalidInput("missing replay option")
        }
        try require(input.hasPrefix("/") && output.hasPrefix("/"), "absolute owned paths required")
        try require(hash.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    "invalid input hash")
        self.input = URL(fileURLWithPath: input); self.output = URL(fileURLWithPath: output, isDirectory: true)
        self.inputSHA256 = hash; self.arm = arm
    }
}
