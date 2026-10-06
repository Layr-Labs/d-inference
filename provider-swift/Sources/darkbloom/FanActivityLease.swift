import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import OSLog

/// Best-effort provider-activity lease for the optional root fan helper.
/// Absence or failure of the helper must never block inference startup.
actor FanActivityLease {
    private let logger = Logger(
        subsystem: "io.darkbloom.provider",
        category: "fan-lease"
    )
    private let providerVersion: String
    private let helperURL: URL
    private let machServiceName: String
    private(set) var running = false
    private var connection: FanXPCConnectionBox?
    private var renewalTask: Task<Void, Never>?
    private(set) var lastReportedError: String?

    /// Production uses the installed helper path and its launchd service.
    /// Tests pass a temp file and a service name that nothing registers.
    init(
        providerVersion: String,
        helperURL: URL = FanServicePaths.production.helper,
        machServiceName: String = FanIPC.machServiceName
    ) {
        self.providerVersion = providerVersion
        self.helperURL = helperURL
        self.machServiceName = machServiceName
    }

    var hasConnection: Bool { connection != nil }

    func start() {
        guard !running else { return }
        running = true
        renew()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            FanIPC.renewalIntervalSeconds * 1_000_000_000
                        )
                    )
                } catch {
                    return
                }
                await self?.renew()
            }
        }
    }

    func stop() {
        guard running || connection != nil else { return }
        running = false
        renewalTask?.cancel()
        renewalTask = nil

        if let proxy = proxy() {
            proxy.releaseProviderActivity { _ in }
        }
        // Session invalidation is itself a fail-safe release signal. It covers
        // a lost reply and makes clean provider shutdown restore Auto promptly.
        connection?.value.invalidate()
        connection = nil
    }

    private func renew() {
        guard running else { return }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            connection?.value.invalidate()
            connection = nil
            return
        }
        if connection == nil {
            connect()
        }
        proxy()?.renewProviderActivity(
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: providerVersion
        ) { [weak self] data in
            Task { await self?.handleRenewalReply(data) }
        }
    }

    private func proxy() -> DarkbloomFanHelperProtocol? {
        guard let connection else { return nil }
        return connection.value.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            guard let connection else { return }
            Task { await self?.connectionLost(connection) }
        } as? DarkbloomFanHelperProtocol
    }

    private func connect() {
        let rawConnection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        let newConnection = FanXPCConnectionBox(rawConnection)
        rawConnection.remoteObjectInterface = NSXPCInterface(
            with: DarkbloomFanHelperProtocol.self
        )
        rawConnection.setCodeSigningRequirement(
            FanCodeRequirements.helperRequirement()
        )
        rawConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            Task { await self?.connectionLost(newConnection) }
        }
        rawConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            Task { await self?.connectionLost(newConnection) }
        }
        rawConnection.resume()
        connection = newConnection
    }

    private func connectionLost(_ lostConnection: FanXPCConnectionBox) {
        guard connection === lostConnection else { return }
        connection = nil
    }

    func handleRenewalReply(_ data: Data) {
        do {
            let reply = try FanIPCCoding.decode(FanIPCReply.self, from: data)
            guard !reply.ok else {
                lastReportedError = nil
                return
            }
            reportOnce(reply.message ?? "fan helper rejected the provider lease")
        } catch {
            reportOnce("invalid fan helper lease reply: \(error)")
        }
    }

    private func reportOnce(_ message: String) {
        guard lastReportedError != message else { return }
        lastReportedError = message
        logger.error("\(message, privacy: .public)")
    }
}

private final class FanXPCConnectionBox: @unchecked Sendable {
    let value: NSXPCConnection

    init(_ value: NSXPCConnection) {
        self.value = value
    }
}

func withFanActivityLease<T>(
    providerVersion: String,
    operation: () async throws -> T
) async rethrows -> T {
    try await withFanActivityLease(
        FanActivityLease(providerVersion: providerVersion),
        operation: operation
    )
}

func withFanActivityLease<T>(
    _ lease: FanActivityLease,
    operation: () async throws -> T
) async rethrows -> T {
    await lease.start()
    return try await withTaskCancellationHandler {
        do {
            let value = try await operation()
            await lease.stop()
            return value
        } catch {
            await lease.stop()
            throw error
        }
    } onCancel: {
        Task { await lease.stop() }
    }
}
