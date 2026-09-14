import Darwin
import Foundation
import SandboxRuntime

struct AccountlessOfflineCollector {
    let journal: AccountlessCollectionJournal
    var verifier = AccountlessInstalledPayloadVerifier()
    var didRemove: (String) throws -> Void = { _ in }

    func collect(dataDirectory: URL, volumeUUID: UUID) throws {
        try journal.requireActive()
        let boot = journal.boot, payload = boot.staging.plan
        let root = try AccountlessOfflineDirectory(path: dataDirectory)
        try verifier.verify(dataDirectory: dataDirectory, plan: payload)
        if try journal.removalPlan() == nil {
            let result = try root.descend(payload.stageRelativePath + "/result")
            let bytes = try read(result, name: "receipt.json", maximumBytes: 16 * 1024, allowEmpty: false)
            let decoded = try AccountlessJournalJSON.decode(AccountlessInstallationResult.self, bytes)
            _ = try decoded.completedInstallation(candidate: boot.staging.candidate)
            var logs: [String: Data] = [:]
            for name in ["installer.log", "helper.log"] { logs[name] = try read(result, name: name, maximumBytes: 65536, allowEmpty: true) }
            try journal.recordResult(bytes, logs: logs)
            try journal.recordRemovalPlan(AccountlessCollectionRemovalPlan.capture(data: root, boot: boot, volumeUUID: volumeUUID))
        }
        guard let plan = try journal.removalPlan(), let result = try journal.resultData() else {
            throw AccountlessInstallationError.invalidBinding
        }
        try plan.validate(boot: boot)
        guard plan.volumeUUID == volumeUUID else { throw AccountlessDiskError.bindingChanged }
        try journal.recordRemovalPlan(plan)
        _ = try AccountlessJournalJSON.decode(AccountlessInstallationResult.self, result).completedInstallation(candidate: boot.staging.candidate)
        try AccountlessTemporaryPayloadRemoval(data: root, payload: payload, plan: plan, didRemove: didRemove).run()
        try verifier.verify(dataDirectory: dataDirectory, plan: payload)
        try root.requireBound(to: dataDirectory)
        try journal.recordRemoved()
    }

    private func read(_ directory: AccountlessOfflineDirectory, name: String, maximumBytes: Int, allowEmpty: Bool) throws -> Data {
        let file = try directory.openFile(name, mode: 0o600, maximumBytes: maximumBytes, allowEmpty: allowEmpty)
        defer { close(file) }
        let bytes = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: maximumBytes, allowEmpty: allowEmpty)
        try directory.requireNamed(file, name: name)
        return bytes
    }
}
