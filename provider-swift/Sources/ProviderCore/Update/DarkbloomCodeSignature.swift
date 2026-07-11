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
        try BoundedProcess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: arguments,
            timeout: 120)
        #endif
    }
}
