import Foundation

enum DarkbloomCodeSignature {
    static let teamID = "SLDQ2GJ6TL"
    static let bundleIdentifier = "io.darkbloom.provider"
    static let designatedRequirement =
        "anchor apple generic and identifier \"\(bundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""

    enum Policy: Sendable, Equatable {
        case darkbloomProduction
        case structuralForIsolatedTest
    }

    static func verify(
        _ target: URL,
        deep: Bool,
        policy: Policy = .darkbloomProduction
    ) throws {
        #if canImport(Darwin)
        var arguments = ["--verify", "--strict", "--verbose=2"]
        if deep { arguments.append("--deep") }
        if policy == .darkbloomProduction {
            arguments.append("-R=\(designatedRequirement)")
        }
        arguments.append(target.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "codesign exited \(process.terminationStatus)"
            throw NSError(
                domain: "DarkbloomCodeSignature",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        #endif
    }
}
