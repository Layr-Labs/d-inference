import Foundation

/// Typed boot-permit wrapper over the root-controlled publication contract.
final class AccountlessBootPermitFile {
    private let file: AccountlessRootRecordFile
    init(path: URL) throws { file = try .init(path: path) }
    static func creationPath(_ path: URL) throws -> URL { try AccountlessRootRecordFile.creationPath(path) }
    static func read(_ path: URL) throws -> AccountlessBootPermit { try .decode(AccountlessRootRecordFile.read(path)) }
    func containsMatching(_ data: Data) throws -> Bool { try file.containsMatching(data) }
    func publish(_ data: Data) throws {
        _ = try AccountlessBootPermit.decode(data)
        try file.publish(data)
    }
}
