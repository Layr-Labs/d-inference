import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

struct AccountlessBaseRootInput {
    let owner: HostUserIdentity
    let reservation: Data
    let candidate: AccountlessBaseCandidateRecord

    init(_ options: AccountlessBaseOptions) throws {
        guard getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw SandboxRuntimeError.unsupported("accountless payload and staging require the root operator")
        }
        owner = try HostUserIdentityBinding.decode(HostUserIdentityFile.read(options.hostIdentityFile),
            hostID: options.hostID).host_user
        guard try HostUserAccountLookup.lookup(owner) == owner else { throw HostUserIdentityError.identityMismatch }
        try HostUserAccountLookup.requireOwnedHome(owner)
        reservation = try LumeRootBaseImageGuard.readReservation(storage: options.storage, name: options.name,
            ownerUID: owner.uid, ownerGID: owner.primaryGID)
        try SandboxJSONIntegrity.requireNoDuplicateKeys(reservation)
        candidate = try JSONDecoder().decode(AccountlessBaseCandidateRecord.self, from: reservation)
        guard candidate.isValid, candidate.source.name == options.name else { throw AccountlessBaseCandidateError.invalidRecord }
    }

    static func plan(at directory: URL, candidate: AccountlessBaseCandidateRecord) throws -> AccountlessInstallationPayloadPlan {
        let parent = try AccountlessOfflineDirectory(path: directory)
        let file = try parent.openFile("plan.json", mode: 0o400, maximumBytes: 32 * 1024)
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 32 * 1024)
        try parent.requireNamed(file, name: "plan.json"); try parent.requireBound(to: directory)
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        let plan = try JSONDecoder().decode(AccountlessInstallationPayloadPlan.self, from: data)
        try plan.validate(candidate: candidate)
        return plan
    }
}
