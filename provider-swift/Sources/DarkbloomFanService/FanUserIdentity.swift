import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum FanUserIdentityError: Error, CustomStringConvertible {
    case unknownUID(UInt32)
    case invalidUsername
    case directoryQueryFailed
    case invalidGeneratedUID

    public var description: String {
        switch self {
        case .unknownUID(let uid): return "no local account exists for UID \(uid)"
        case .invalidUsername: return "local account name is invalid"
        case .directoryQueryFailed: return "could not query the account GeneratedUID"
        case .invalidGeneratedUID: return "the account has no valid GeneratedUID"
        }
    }
}

public enum FanUserIdentity {
    public static func generatedUID(for uid: UInt32) throws -> String {
        let username = try username(for: uid)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(username)", "GeneratedUID"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            throw FanUserIdentityError.directoryQueryFailed
        }
        guard process.terminationStatus == 0 else {
            throw FanUserIdentityError.directoryQueryFailed
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard let raw = text.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw)
        else {
            throw FanUserIdentityError.invalidGeneratedUID
        }
        return uuid.uuidString
    }

    private static func username(for uid: UInt32) throws -> String {
        #if canImport(Darwin)
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        let status = getpwuid_r(
            uid_t(uid),
            &record,
            &buffer,
            buffer.count,
            &result
        )
        guard status == 0, result != nil, let name = record.pw_name else {
            throw FanUserIdentityError.unknownUID(uid)
        }
        let username = String(cString: name)
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        guard !username.isEmpty,
              username.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw FanUserIdentityError.invalidUsername
        }
        return username
        #else
        throw FanUserIdentityError.unknownUID(uid)
        #endif
    }
}
