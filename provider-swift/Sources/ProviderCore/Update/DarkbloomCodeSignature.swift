import DarkbloomSigningIdentity
import Foundation

enum DarkbloomCodeSignature {
    static let teamID = DarkbloomSigningIdentity.teamID
    static let bundleIdentifier = "io.darkbloom.provider"
    static let designatedRequirement =
        DarkbloomSigningIdentity.requirement(identifier: bundleIdentifier)
    static let fanHelperIdentifier = "io.darkbloom.fan-helper"
    static let fanHelperDesignatedRequirement =
        DarkbloomSigningIdentity.requirement(identifier: fanHelperIdentifier)

    enum Policy: Sendable, Equatable {
        case darkbloomProduction
        case darkbloomFanHelper
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
        } else if policy == .darkbloomFanHelper {
            arguments.append("-R=\(fanHelperDesignatedRequirement)")
        }
        arguments.append(target.path)
        try BoundedProcess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: arguments,
            timeout: 120)
        #endif
    }
}
