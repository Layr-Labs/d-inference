import Darwin
import Foundation
import Security
import SandboxGuestProtocol
import SandboxRuntime

public struct GuestConfiguration: Codable, Sendable {
    public let version: Int
    public let instanceID: UUID
    public let credential: Data
    public let workspacePath: String
    public let tenantUID: UInt32
    public let tenantGID: UInt32

    static func requireVirtualizedRoot() throws {
        var virtualized: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard getuid() == 0, geteuid() == 0,
              sysctlbyname("kern.hv_vmm_present", &virtualized, &length, nil, 0) == 0,
              virtualized == 1 else { throw GuestProtocolError.invalidConfiguration }
    }

    public static func loadProduction(from path: String) throws -> Self {
        guard geteuid() == 0, getuid() == 0 else { throw GuestProtocolError.invalidConfiguration }
        let executable = try signedExecutable()
        _ = executable
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let parent = URL(fileURLWithPath: canonical).deletingLastPathComponent().path
        try requireRootAuthority(parent, directory: true)
        let descriptor = open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { close(descriptor) }
        try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              (1...8192).contains(info.st_size)
        else { throw GuestProtocolError.invalidConfiguration }
        let bytes = try GuestDescriptor.read(descriptor, count: Int(info.st_size))
        let result = try JSONDecoder().decode(Self.self, from: bytes)
        guard result.version == 1, result.credential.count == 32,
              result.tenantUID == 2001, result.tenantGID == 2001,
              result.workspacePath == "/workspace",
              let account = getpwuid(result.tenantUID),
              String(cString: account.pointee.pw_name) == "darkbloomtenant",
              account.pointee.pw_gid == result.tenantGID
        else { throw GuestProtocolError.invalidConfiguration }
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist("darkbloomtenant", Int32(result.tenantGID), &groups, &count) >= 0,
              // Darwin may report its implicit everyone/localaccounts groups.
              // Every supplementary group is removed before tenant execution.
              groups.prefix(Int(count)).allSatisfy({ [Int32(result.tenantGID), 12, 61].contains($0) })
        else { throw GuestProtocolError.invalidConfiguration }
        return result
    }

    public static func signedExecutable() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        try requireRootAuthority(executable.path, directory: false)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"io.darkbloom.sandbox.guest\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw GuestProtocolError.invalidConfiguration }
        return executable
    }

    private static func requireRootAuthority(_ path: String, directory: Bool) throws {
        let components = path.split(separator: "/")
        var current = ""
        for (index, component) in components.enumerated() {
            current += "/\(component)"
            var info = stat()
            guard lstat(current, &info) == 0, info.st_uid == 0,
                  info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == ((index == components.count - 1 && !directory) ? S_IFREG : S_IFDIR)
            else { throw GuestProtocolError.invalidConfiguration }
            let descriptor = open(current, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GuestProtocolError.invalidConfiguration }
            defer { close(descriptor) }
            try SandboxAuthorityFileSystem.requireNoExtendedACL(descriptor)
        }
    }
}

enum GuestDescriptor {
    static func read(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GuestProtocolError.disconnected }
                offset += n
            }
        }
        return data
    }

    static func write(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GuestProtocolError.disconnected }
                offset += n
            }
        }
    }
}
