import FanControlIPC
import Foundation

struct FanHelperStatus: Sendable, Equatable {
    let engaged: Bool
    let temperatureCelsius: Double?
    let targetRPMs: String?
}

enum FanHelperClientError: Error, LocalizedError {
    case unavailable(String)
    case timeout
    case invalidResponse
    case incompatibleVersion(expected: Int, actual: Int)
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "fan helper is unavailable: \(detail)"
        case .timeout:
            return "fan helper did not respond before the safety timeout"
        case .invalidResponse:
            return "fan helper returned an invalid response"
        case .incompatibleVersion(let expected, let actual):
            return "fan helper protocol \(actual) is incompatible with this CLI (expected \(expected)); reinstall the helper"
        case .helper(let message):
            return message
        }
    }
}

final class FanHelperClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(
            machServiceName: FanControlIPC.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: FanControlXPCProtocol.self
        )
        connection.setCodeSigningRequirement(
            FanControlIPC.helperRequirement
        )
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    func verifyProtocol() throws {
        let reply = PendingFanReply<Int>()
        try proxy(reply: reply).getProtocolVersion {
            reply.resolve(.success($0))
        }
        let version = try reply.wait()
        guard version == FanControlIPC.protocolVersion else {
            throw FanHelperClientError.incompatibleVersion(
                expected: FanControlIPC.protocolVersion,
                actual: version
            )
        }
    }

    func acquireLease(
        speedPercent: Double,
        triggerTemperatureCelsius: Double
    ) throws -> UUID {
        let reply = PendingFanReply<(NSString?, NSString?)>()
        try proxy(reply: reply).acquireLease(
            speedPercent: speedPercent,
            triggerTemperatureCelsius: triggerTemperatureCelsius
        ) { lease, error in
            reply.resolve(.success((lease, error)))
        }

        let response = try reply.wait()
        if let error = response.1 {
            throw FanHelperClientError.helper(error as String)
        }
        guard let rawLease = response.0,
              let lease = UUID(uuidString: rawLease as String) else {
            throw FanHelperClientError.invalidResponse
        }
        return lease
    }

    func renewLease(
        _ lease: UUID,
        sequence: UInt64,
        inferenceActive: Bool
    ) throws -> FanHelperStatus {
        typealias Response = (Bool, Double, NSString?, NSString?)
        let reply = PendingFanReply<Response>()
        try proxy(reply: reply).renewLease(
            lease.uuidString as NSString,
            sequence: sequence,
            inferenceActive: inferenceActive
        ) { engaged, temperature, targets, error in
            reply.resolve(.success((
                engaged,
                temperature,
                targets,
                error
            )))
        }

        let response = try reply.wait()
        if let error = response.3 {
            throw FanHelperClientError.helper(error as String)
        }
        return FanHelperStatus(
            engaged: response.0,
            temperatureCelsius: response.1 >= 0 ? response.1 : nil,
            targetRPMs: response.2.map { $0 as String }
        )
    }

    func releaseLease(_ lease: UUID) throws {
        let reply = PendingFanReply<NSString?>()
        try proxy(reply: reply).releaseLease(
            lease.uuidString as NSString
        ) {
            reply.resolve(.success($0))
        }
        if let error = try reply.wait() {
            throw FanHelperClientError.helper(error as String)
        }
    }

    func restoreAutomatic() throws {
        let reply = PendingFanReply<NSString?>()
        try proxy(reply: reply).restoreAutomatic {
            reply.resolve(.success($0))
        }
        if let error = try reply.wait() {
            throw FanHelperClientError.helper(error as String)
        }
    }

    private func proxy<Value>(
        reply: PendingFanReply<Value>
    ) throws -> FanControlXPCProtocol {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            reply.resolve(.failure(
                FanHelperClientError.unavailable(
                    error.localizedDescription
                )
            ))
        }
        guard let typed = proxy as? FanControlXPCProtocol else {
            throw FanHelperClientError.invalidResponse
        }
        return typed
    }
}

private final class PendingFanReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        let shouldSignal = lock.withLock {
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(
        timeout: TimeInterval = 5
    ) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw FanHelperClientError.timeout
        }
        return try lock.withLock {
            guard let result else {
                throw FanHelperClientError.invalidResponse
            }
            return try result.get()
        }
    }
}
