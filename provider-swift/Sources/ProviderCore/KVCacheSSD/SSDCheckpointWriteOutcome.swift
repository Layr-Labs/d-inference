import Foundation

extension SSDHybridCheckpointStore {
    /// Do not parse/log error descriptions: they can contain paths or native
    /// details. Unknown producer/crypto errors retain the legacy fallback.
    static func freshWriteFailureOutcome(_ error: Error) -> PrefixCacheDonationOutcome {
        if case SSDBlockStoreError.posixFailure(_, let code) = error {
            return code == ENOSPC ? .diskSpaceInsufficient : .writeIOFailed
        }
        if case SSDBlockStoreError.ioFailure = error { return .writeIOFailed }
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            return value.code == Int(ENOSPC) ? .diskSpaceInsufficient : .writeIOFailed
        }
        if value.domain == NSCocoaErrorDomain {
            return value.code == NSFileWriteOutOfSpaceError ? .diskSpaceInsufficient : .writeIOFailed
        }
        return .writeFailed
    }
}
