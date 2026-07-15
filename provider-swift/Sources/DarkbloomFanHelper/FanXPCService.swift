import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import OSLog

final class FanXPCService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "io.darkbloom.fan", category: "xpc")
    private let listener: NSXPCListener
    private let daemon: FanDaemon
    private let authorization: FanPeerAuthorizationPolicy

    init(
        daemon: FanDaemon,
        configuredUID: UInt32,
        configuredUserUUID: String
    ) {
        self.daemon = daemon
        self.authorization = FanPeerAuthorizationPolicy(
            configuredUID: configuredUID,
            configuredUserUUID: configuredUserUUID
        )
        self.listener = NSXPCListener(machServiceName: FanIPC.machServiceName)
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(
            FanCodeRequirements.providerRequirement()
        )
    }

    func start() {
        listener.resume()
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let uid = UInt32(connection.effectiveUserIdentifier)
        let currentUserUUID = uid == 0
            ? nil
            : try? FanUserIdentity.generatedUID(for: uid)
        guard authorization.allows(
            effectiveUID: uid,
            currentUserUUID: currentUserUUID
        ) else {
            logger.error("rejected fan XPC peer uid=\(uid, privacy: .public)")
            return false
        }

        let session = FanXPCSession(
            daemon: daemon,
            sessionID: UUID(),
            effectiveUID: uid
        )
        connection.exportedInterface = NSXPCInterface(
            with: DarkbloomFanHelperProtocol.self
        )
        connection.exportedObject = session
        connection.invalidationHandler = { [daemon, sessionID = session.sessionID] in
            Task { await daemon.sessionInvalidated(sessionID) }
        }
        connection.interruptionHandler = { [daemon, sessionID = session.sessionID] in
            Task { await daemon.sessionInvalidated(sessionID) }
        }
        connection.resume()
        return true
    }
}

final class FanXPCSession: NSObject, DarkbloomFanHelperProtocol, @unchecked Sendable {
    let sessionID: UUID
    private let daemon: FanDaemon
    private let effectiveUID: UInt32

    init(daemon: FanDaemon, sessionID: UUID, effectiveUID: UInt32) {
        self.daemon = daemon
        self.sessionID = sessionID
        self.effectiveUID = effectiveUID
    }

    func renewProviderActivity(
        protocolVersion: Int,
        providerVersion: String,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        Task {
            let result = await daemon.renewLease(
                sessionID: sessionID,
                protocolVersion: protocolVersion,
                providerVersion: providerVersion
            )
            reply(encode(result))
        }
    }

    func releaseProviderActivity(withReply reply: @escaping @Sendable (Data) -> Void) {
        Task {
            reply(encode(await daemon.releaseLease(sessionID: sessionID)))
        }
    }

    func status(withReply reply: @escaping @Sendable (Data) -> Void) {
        Task {
            reply(encode(await daemon.status()))
        }
    }

    func restoreAutomatic(withReply reply: @escaping @Sendable (Data) -> Void) {
        guard effectiveUID == 0 else {
            reply(encode(FanIPCReply(
                ok: false,
                message: "automatic restore requires root"
            )))
            return
        }
        Task {
            reply(encode(await daemon.emergencyRestore()))
        }
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        do {
            return try FanIPCCoding.encode(value)
        } catch {
            return Data(
                #"{"ok":false,"message":"fan helper encoding failure","helperVersion":"2","protocolVersion":2}"#.utf8
            )
        }
    }
}
