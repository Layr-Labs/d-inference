import Foundation

extension NativeMemberIdentity {
    static let maximumBytes = 1024

    func canonical() throws -> Data {
        try validate()
        var b = Data("DBNID\u{1}".utf8)
        switch evidence { case .legacyMDA: b.append(1); case .qualifiedAppAttest: b.append(2) }
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ n: T) {
            for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        func text(_ s: String) { let raw = Data(s.utf8); integer(UInt32(raw.count)); b.append(raw) }
        for s in [providerID, controlPublicKey, processPublicKey] { text(s) }
        b.append(binarySHA256); b.append(metallibSHA256); integer(releasePolicyGeneration)
        switch evidence {
        case let .legacyMDA(serial): text(serial)
        case let .qualifiedAppAttest(account, machine, credential, proof):
            for s in [account, machine, credential, proof] { text(s) }
        }
        guard b.count <= Self.maximumBytes else { throw NativeMemberIdentityError.invalid }
        return b
    }

    init(canonical bytes: Data) throws {
        guard bytes.count <= Self.maximumBytes else { throw NativeMemberIdentityError.invalid }
        let raw = Array(bytes)
        var offset = 0
        func take(_ n: Int) throws -> Data {
            guard n >= 0, n <= raw.count - offset else { throw NativeMemberIdentityError.invalid }
            defer { offset += n }; return Data(raw[offset..<(offset + n)])
        }
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
            try take(T.bitWidth / 8).reduce(T(0)) { ($0 << 8) | T($1) }
        }
        func text() throws -> String {
            let count = try integer(UInt32.self)
            guard count <= 128, let s = String(data: try take(Int(count)), encoding: .utf8) else { throw NativeMemberIdentityError.invalid }
            return s
        }
        guard try take(6) == Data("DBNID\u{1}".utf8) else { throw NativeMemberIdentityError.invalid }
        let kind = try integer(UInt8.self)
        let provider = try text(), control = try text(), process = try text()
        let binary = try take(32), metal = try take(32), generation = try integer(UInt64.self)
        let proof: Evidence
        switch kind {
        case 1: proof = .legacyMDA(serial: try text())
        case 2: proof = .qualifiedAppAttest(accountID: try text(), machineID: try text(), credentialID: try text(), proofSessionID: try text())
        default: throw NativeMemberIdentityError.invalid
        }
        try self.init(providerID: provider, controlPublicKey: control, processPublicKey: process,
            binarySHA256: binary, metallibSHA256: metal, releasePolicyGeneration: generation, evidence: proof)
        guard offset == raw.count, try canonical() == bytes else { throw NativeMemberIdentityError.invalid }
    }
}
