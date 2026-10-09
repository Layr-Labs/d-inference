import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import Foundation

/// Optional, metadata-only entry. It returns before WorkerConfiguration, model
/// loading, bootstrap, resource admission or MLX initialization is invoked.
enum WorkerCapabilityCommand {
    struct Arguments {
        let configurationPath: String, manifestPath: String, expectedExecutableSHA256: String
        init(_ values: [String]) throws {
            guard values.count == 7, values[0] == "--describe-runtime",
                  values[1] == "--config", values[3] == "--manifest", values[5] == "--expected-executable-sha256",
                  values[6].utf8.count == 64, values[6].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  [values[2], values[4]].allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 4096 }) else {
                throw WorkerCapabilityError.invalid("Expected --describe-runtime --config PATH --manifest PATH --expected-executable-sha256 SHA256")
            }
            configurationPath = values[2]; manifestPath = values[4]; expectedExecutableSHA256 = values[6]
        }
    }

    static func run(arguments: [String]) throws {
        let request = try Arguments(arguments)
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        signal(SIGPIPE, SIG_IGN)
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(15)
        defer { alarm(0) }
        let executable = try executablePath()
        let actual = try WorkerCapabilityInput.hash(executable, maximumBytes: 256 * 1024 * 1024, deadline: deadline)
        guard actual == request.expectedExecutableSHA256 else {
            throw WorkerCapabilityError.invalid("Installed executable bytes differ from the expected binary SHA-256")
        }
        let configuration = try WorkerCapabilityInput.read(request.configurationPath, maximumBytes: 1_048_576, deadline: deadline)
        let manifest = try WorkerCapabilityInput.read(request.manifestPath, maximumBytes: 4_194_304, deadline: deadline)
        let capability = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                                    runtimeBinarySHA256: actual)
        try write(ClusterRuntimeCapabilityCodec.encode(capability), deadline: deadline)
    }

    private static func executablePath() throws -> String {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 1, capacity <= 4096 else { throw WorkerCapabilityError.invalid("Executable path exceeds bound") }
        var bytes = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&bytes, &capacity) == 0 else { throw WorkerCapabilityError.invalid("Cannot resolve installed executable") }
        guard let path = String(bytes: bytes.prefix(while: { $0 != 0 }).map({ UInt8(bitPattern: $0) }), encoding: .utf8) else {
            throw WorkerCapabilityError.invalid("Installed executable path is not UTF-8")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func write(_ data: Data, deadline: UInt64) throws {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WorkerCapabilityError.invalid("Cannot bound metadata output")
        }
        defer { _ = fcntl(STDOUT_FILENO, F_SETFL, flags) }
        var offset = 0
        while offset < data.count {
            try WorkerCapabilityInput.check(deadline)
            let count = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let result = poll(&descriptor, 1, 100)
                if result < 0 && errno != EINTR { throw WorkerCapabilityError.invalid("Metadata output poll failed") }
                continue
            }
            guard count > 0 else { throw WorkerCapabilityError.invalid("Metadata output failed") }
            offset += count
        }
        try WorkerCapabilityInput.check(deadline)
    }
}
