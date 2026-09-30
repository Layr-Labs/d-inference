import Foundation
import XCTest

enum MiMoTestPrerequisites {
    enum Failure: Error { case invalidOptIn(String) }

    static func requireOptIn(_ key: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let value = environment[key] else {
            throw XCTSkip("Set \(key)=1 to run this isolated fixture gate")
        }
        guard value == "1" else { throw Failure.invalidOptIn(key) }
    }
}
