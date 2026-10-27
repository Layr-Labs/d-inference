import Foundation

/// Uses the original completed P2P and group lifetime. Single synchronous owner,
/// no receive task, no second socket, no model evaluation during a control call.
final class Gemma4MTPPullChannel {
    enum Role { case target, assistant }
    let collective: Collective
    let role: Role
    let peer: Int
    let scopeSHA256: String
    private(set) var sequence: UInt64 = 0
    private var pending: Gemma4MTPPullRecord?
    private var busy = false, failed = false
    private let controlOperations: Gemma4MTPControlOperation?
    // Only an original owner's scalar lifetime method, never a borrowed MLX
    // error-context closure. Failure retention may safely retain that owner.
    private let controlLifetimeCheck: (() throws -> Void)?

    init(collective: Collective, role: Role, targetRank: Int, scopeSHA256: String,
         controlOperations: Gemma4MTPControlOperation? = nil,
         controlLifetimeCheck: (() throws -> Void)? = nil) throws {
        guard collective.size == 2, (0..<2).contains(targetRank),
              collective.rank == (role == .target ? targetRank : 1-targetRank),
              (controlOperations == nil) == (controlLifetimeCheck == nil),
              Gemma4MTPPullRecord.byteCount == 16_384 else {
            throw ProbeError("Remote MTP channel has the wrong original rank/group")
        }
        self.collective = collective; self.role = role; peer = 1-collective.rank; self.scopeSHA256 = scopeSHA256
        self.controlOperations = controlOperations; self.controlLifetimeCheck = controlLifetimeCheck
    }
    func exchange(_ command: Gemma4MTPPullRecord, expecting: Gemma4MTPPullRecord.Kind,
                  transfer: () throws -> Void = {}, check: () throws -> Void) throws -> Gemma4MTPPullRecord {
        try enter(); defer { busy = false }
        do {
            guard role == .target, command.sequence == sequence, command.scopeSHA256 == scopeSHA256 else { throw ProbeError("Remote MTP command identity differs") }
            try send(command, check: check)
            try transfer()
            let response = try receive(check: check)
            guard response.kind == expecting, response.sequence == sequence, response.scopeSHA256 == scopeSHA256 else { throw ProbeError("Remote MTP response scope/order differs") }
            sequence += 1
            return response
        } catch { failed = true; throw error }
    }
    func receiveCommand(check: () throws -> Void) throws -> Gemma4MTPPullRecord {
        try enter(); defer { busy = false }
        do {
            guard role == .assistant, pending == nil else { throw ProbeError("Remote MTP receive is out of turn") }
            let command = try receive(check: check)
            guard command.sequence == sequence, command.scopeSHA256 == scopeSHA256 else { throw ProbeError("Remote MTP command is stale or foreign") }
            pending = command; return command
        } catch { failed = true; throw error }
    }
    func reply(_ response: Gemma4MTPPullRecord, check: () throws -> Void) throws {
        try enter(); defer { busy = false }
        do {
            guard role == .assistant, let pending, response.sequence == pending.sequence,
                  response.scopeSHA256 == scopeSHA256 else { throw ProbeError("Remote MTP reply has no current command") }
            try send(response, check: check); self.pending = nil; sequence += 1
        } catch { failed = true; throw error }
    }
    private func enter() throws {
        guard !failed, !busy, sequence < UInt64.max else { throw ProbeError("Remote MTP channel failed, reentered or exhausted") }
        busy = true
    }
    private func send(_ value: Gemma4MTPPullRecord, check: () throws -> Void) throws {
        if let controlOperations, let controlLifetimeCheck {
            try controlOperations.send(resourceCheck:check,lifetimeCheck:{
                guard !self.failed, self.busy else { throw ProbeError("Remote MTP control owner is no longer active") }
                try controlLifetimeCheck()
            }) { checkpoint in
                try collective.sendControlCompleted(value.encode(),to:peer,
                    maximumBytes:Gemma4MTPPullRecord.byteCount,check:checkpoint.check)
            }
            return
        }
        try check()
        try collective.sendControlCompleted(value.encode(), to: peer,
            maximumBytes: Gemma4MTPPullRecord.byteCount, check: check)
        try check()
    }
    private func receive(check: () throws -> Void) throws -> Gemma4MTPPullRecord {
        if let controlOperations, let controlLifetimeCheck {
            let data = try controlOperations.receive(resourceCheck:check,lifetimeCheck:{
                guard !self.failed, self.busy else { throw ProbeError("Remote MTP control owner is no longer active") }
                try controlLifetimeCheck()
            }) { checkpoint in
                try collective.receiveControlCompleted(byteCount:Gemma4MTPPullRecord.byteCount,
                    from:peer,maximumBytes:Gemma4MTPPullRecord.byteCount,check:checkpoint.check)
            }
            return try Gemma4MTPPullRecord.decode(data)
        }
        try check()
        let data = try collective.receiveControlCompleted(byteCount: Gemma4MTPPullRecord.byteCount,
            from: peer, maximumBytes: Gemma4MTPPullRecord.byteCount, check: check)
        try check(); return try Gemma4MTPPullRecord.decode(data)
    }
}
