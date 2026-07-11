import FanControlCore
import FanControlIPC
import Foundation

final class FanHelperSession: NSObject, FanControlXPCProtocol {
    private let controller: FanLeaseController
    private let stateLock = NSLock()
    private var leaseID: UUID?

    init(controller: FanLeaseController) {
        self.controller = controller
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
        if stateLock.withLock({ leaseID != nil }) {
            reply(nil, "this connection already owns a lease")
            return
        }

        do {
            let id = try controller.acquireLease(
                speedPercent: speedPercent,
                triggerTemperatureCelsius: triggerTemperatureCelsius
            )
            stateLock.withLock {
                leaseID = id
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
            try? controller.releaseLease(id)
            stateLock.withLock {
                self.leaseID = nil
            }
            reply(false, -1, nil, error.localizedDescription as NSString)
        }
    }

    func releaseLease(
        _ leaseID: NSString,
        withReply reply: @escaping (NSString?) -> Void
    ) {
        guard let id = UUID(uuidString: leaseID as String),
              stateLock.withLock({ self.leaseID == id }) else {
            reply("lease does not belong to this connection")
            return
        }

        do {
            try controller.releaseLease(id)
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
            defer { leaseID = nil }
            return leaseID
        }
        if let id {
            try? controller.releaseLease(id)
        }
    }
}
