import Foundation
import ProviderCoreFoundation

/// Binds each asynchronous Local API probe to one immutable discovery
/// revision. Replacing or invalidating `local.json` cancels the old task and
/// makes every result carrying its prior ticket unpublishable.
@MainActor
final class LocalAPIProbeCoordinator {
    struct Ticket: Equatable {
        let info: LocalEndpointInfo
        let revision: UInt64
    }

    private struct InFlight {
        let id: UUID
        let ticket: Ticket
        let task: Task<Void, Never>
    }

    private(set) var info: LocalEndpointInfo?
    private var revision: UInt64
    private var inFlight: InFlight?

    init(initialInfo: LocalEndpointInfo?) {
        info = initialInfo
        revision = initialInfo == nil ? 0 : 1
    }

    deinit {
        inFlight?.task.cancel()
    }

    @discardableResult
    func adopt(_ nextInfo: LocalEndpointInfo?) -> Bool {
        guard nextInfo != info else { return false }
        info = nextInfo
        revision &+= 1
        cancel()
        return true
    }

    func ticket() -> Ticket? {
        info.map { Ticket(info: $0, revision: revision) }
    }

    func canStart(_ ticket: Ticket) -> Bool {
        inFlight == nil && isCurrent(ticket)
    }

    func install(
        id: UUID,
        ticket: Ticket,
        task: Task<Void, Never>
    ) {
        precondition(canStart(ticket))
        inFlight = InFlight(id: id, ticket: ticket, task: task)
    }

    func accepts(id: UUID, ticket: Ticket) -> Bool {
        guard let inFlight else { return false }
        return inFlight.id == id
            && inFlight.ticket == ticket
            && isCurrent(ticket)
    }

    func finish(id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }

    func cancel() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        revision == ticket.revision && info == ticket.info
    }
}
