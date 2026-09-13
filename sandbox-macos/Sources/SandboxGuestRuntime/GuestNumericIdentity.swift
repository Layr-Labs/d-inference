import Darwin

enum GuestNumericIdentityError: Error, Equatable, Sendable {
    case userRegistered
    case groupRegistered
    case lookupFailed(Int32)
    case lookupExceedsBound
}

/// The CPU guest deliberately has no Directory Services tenant account.
/// Kernel credentials and file ownership use these fixed numeric identities;
/// privileged cron/at clients independently require a resolvable user record.
enum GuestNumericIdentity {
    static let uid: uid_t = 2001
    static let gid: gid_t = 2001
    static let initialBufferBytes = 16 * 1024
    static let maximumBufferBytes = 1024 * 1024

    struct LookupResult {
        let status: Int32
        let found: Bool
    }
    typealias Lookup = (UInt32, UnsafeMutableBufferPointer<CChar>) -> LookupResult

    static func validate(userLookup: Lookup = userRecord, groupLookup: Lookup = groupRecord) throws {
        if try mapped(uid, using: userLookup) { throw GuestNumericIdentityError.userRegistered }
        if try mapped(gid, using: groupLookup) { throw GuestNumericIdentityError.groupRegistered }
    }

    private static func mapped(_ identifier: UInt32, using lookup: Lookup) throws -> Bool {
        var size = initialBufferBytes
        while true {
            var bytes = [CChar](repeating: 0, count: size)
            let result = bytes.withUnsafeMutableBufferPointer { lookup(identifier, $0) }
            if result.status == 0 { return result.found }
            guard result.status == ERANGE else { throw GuestNumericIdentityError.lookupFailed(result.status) }
            guard size < maximumBufferBytes else { throw GuestNumericIdentityError.lookupExceedsBound }
            size *= 2
        }
    }

    static func userRecord(_ identifier: UInt32, _ buffer: UnsafeMutableBufferPointer<CChar>) -> LookupResult {
        var record = passwd(), result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid_t(identifier), &record, buffer.baseAddress!, buffer.count, &result)
        return LookupResult(status: status, found: result != nil)
    }

    static func groupRecord(_ identifier: UInt32, _ buffer: UnsafeMutableBufferPointer<CChar>) -> LookupResult {
        var record = group(), result: UnsafeMutablePointer<group>?
        let status = getgrgid_r(gid_t(identifier), &record, buffer.baseAddress!, buffer.count, &result)
        return LookupResult(status: status, found: result != nil)
    }
}
