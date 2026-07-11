import FanControlCore
import FanControlIPC
import Foundation

final class FanHelperSession: NSObject, FanControlXPCProtocol {
    private let provider: FanControllerProvider
    private let stateLock = NSLock()
    private var leaseID: UUID?
    private var invalidated = false

    init(provider: FanControllerProvider) {
        self.provider = provider
    }

    func getProtocolVersion(
        withReply reply: @escaping (Int) -> Void
    ) {
        reply(FanControlIPC.protocolVersion)
    }

    func acquireLease(
        speedPercent: Double,
        triggerTemperatureCelsius: Double,
        withReply reply: @escaping (NSString?, NSString?) -> Void
    ) {
        if stateLock.withLock({ invalidated || leaseID != nil }) {
            reply(nil, "this connection cannot acquire another lease")
            return
        }

        do {
            let controller = try provider.controller()
            let id = try controller.acquireLease(
                speedPercent: speedPercent,
                triggerTemperatureCelsius: triggerTemperatureCelsius
            )
            let connectionClosed = stateLock.withLock {
                if invalidated {
                    return true
                }
                leaseID = id
                return false
            }
            if connectionClosed {
                controller.cancelLease(id)
                reply(nil, "the XPC connection closed during lease acquisition")
                return
            }
            reply(id.uuidString as NSString, nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func renewLease(
        _ leaseID: NSString,
        sequence: UInt64,
        inferenceActive: Bool,
        withReply reply: @escaping (
            Bool,
            Double,
            NSString?,
            NSString?
        ) -> Void
    ) {
        guard let id = UUID(uuidString: leaseID as String),
              stateLock.withLock({ self.leaseID == id }) else {
            reply(false, -1, nil, "lease does not belong to this connection")
            return
        }

        do {
            let controller = try provider.controller()
            let status = try controller.renewLease(
                id,
                sequence: sequence,
                inferenceActive: inferenceActive
            )
            let targets = status.targetRPMs.isEmpty
                ? nil
                : status.targetRPMs.map { String($0) }
                    .joined(separator: "/") as NSString
            reply(
                status.engaged,
                status.temperatureCelsius ?? -1,
                targets,
                nil
            )
        } catch {
            provider.cancelLeaseIfLoaded(id)
            stateLock.withLock {
                if self.leaseID == id {
                    self.leaseID = nil
                }
            }
            reply(false, -1, nil, error.localizedDescription as NSString)
        }
    }

    func releaseLease(
        _ leaseID: NSString,
        withReply reply: @escaping (NSString?) -> Void
    ) {
        guard let id = UUID(uuidString: leaseID as String) else {
            reply("lease does not belong to this connection")
            return
        }
        let ownedLease = stateLock.withLock { self.leaseID }
        guard let ownedLease else {
            reply(nil)
            return
        }
        guard ownedLease == id else {
            reply("lease does not belong to this connection")
            return
        }

        do {
            let controller = try provider.controller()
            try controller.releaseLease(id)
            stateLock.withLock {
                self.leaseID = nil
            }
            reply(nil)
        } catch FanControlError.leaseNotFound {
            stateLock.withLock {
                self.leaseID = nil
            }
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func restoreAutomatic(
        withReply reply: @escaping (NSString?) -> Void
    ) {
        do {
            let controller = try provider.controller()
            try controller.restoreAutomatic()
            stateLock.withLock {
                leaseID = nil
            }
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func connectionInvalidated() {
        let id = stateLock.withLock { () -> UUID? in
            invalidated = true
            defer { leaseID = nil }
            return leaseID
        }
        if let id {
            provider.cancelLeaseIfLoaded(id)
        }
    }
}
