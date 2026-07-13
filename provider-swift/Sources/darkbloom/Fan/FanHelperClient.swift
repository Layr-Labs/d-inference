import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation

enum FanHelperClientError: Error, CustomStringConvertible {
    case unavailable(String)
    case timedOut
    case invalidReply(String)

    var description: String {
        switch self {
        case .unavailable(let detail): return "fan helper is unavailable: \(detail)"
        case .timedOut: return "fan helper did not reply within 2 seconds"
        case .invalidReply(let detail): return "fan helper returned an invalid reply: \(detail)"
        }
    }
}

struct FanHelperClient {
    func status() throws -> FanServiceStatus {
        let data = try request { proxy, reply in
            proxy.status(withReply: reply)
        }
        do {
            return try FanIPCCoding.decode(FanServiceStatus.self, from: data)
        } catch {
            throw FanHelperClientError.invalidReply(String(describing: error))
        }
    }

    func restoreAutomatic() throws -> FanIPCReply {
        let data = try request { proxy, reply in
            proxy.restoreAutomatic(withReply: reply)
        }
        do {
            return try FanIPCCoding.decode(FanIPCReply.self, from: data)
        } catch {
            throw FanHelperClientError.invalidReply(String(describing: error))
        }
    }

    private func request(
        _ send: (
            DarkbloomFanHelperProtocol,
            @escaping @Sendable (Data) -> Void
        ) -> Void
    ) throws -> Data {
        let connection = NSXPCConnection(
            machServiceName: FanIPC.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: DarkbloomFanHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            FanCodeRequirements.helperRequirement()
        )

        let reply = FanXPCReplyBox()
        connection.interruptionHandler = {
            reply.finish(.failure(.unavailable("connection interrupted")))
        }
        connection.invalidationHandler = {
            reply.finish(.failure(.unavailable("connection invalidated")))
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.finish(.failure(.unavailable(error.localizedDescription)))
        }) as? DarkbloomFanHelperProtocol else {
            connection.invalidate()
            throw FanHelperClientError.unavailable("could not create XPC proxy")
        }

        send(proxy) { data in
            reply.finish(.success(data))
        }
        guard reply.wait(timeout: 2) else {
            connection.invalidate()
            throw FanHelperClientError.timedOut
        }
        connection.invalidate()
        return try reply.result().get()
    }
}

private final class FanXPCReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Result<Data, FanHelperClientError>?

    func finish(_ result: Result<Data, FanHelperClientError>) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func result() -> Result<Data, FanHelperClientError> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(.timedOut)
    }
}
