//! In-memory terminal journal for the Swift provider (protocol v2).
//! Mirrors darkbloom_core::terminal_journal rules for ACK/replay/conflict.

import Foundation

public struct TerminalJournalEntry: Sendable, Equatable {
    public var terminalDigest: String
    public var jobId: String
    public var attemptId: String
    public var leaseId: String
    public var outcome: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var responseHash: String
    public var seSignature: String

    public init(
        terminalDigest: String,
        jobId: String,
        attemptId: String,
        leaseId: String,
        outcome: String,
        promptTokens: Int,
        completionTokens: Int,
        responseHash: String,
        seSignature: String
    ) {
        self.terminalDigest = terminalDigest
        self.jobId = jobId
        self.attemptId = attemptId
        self.leaseId = leaseId
        self.outcome = outcome
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.responseHash = responseHash
        self.seSignature = seSignature
    }
}

public enum TerminalJournalError: Error, Sendable, Equatable {
    case full
    case conflict
}

public final class TerminalJournal: @unchecked Sendable {
    private let capacity: Int
    private var pending: [String: TerminalJournalEntry] = [:]
    private var acked: [String: String] = [:]
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public func append(_ entry: TerminalJournalEntry) throws {
        lock.lock(); defer { lock.unlock() }
        if let prev = pending[entry.attemptId] {
            if prev.terminalDigest != entry.terminalDigest {
                throw TerminalJournalError.conflict
            }
            return
        }
        if acked[entry.terminalDigest] != nil {
            return
        }
        if pending.count >= capacity {
            throw TerminalJournalError.full
        }
        pending[entry.attemptId] = entry
    }

    @discardableResult
    public func ack(attemptId: String, terminalDigest: String, disposition: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let entry = pending.removeValue(forKey: attemptId) {
            if entry.terminalDigest == terminalDigest {
                acked[terminalDigest] = disposition
                return true
            }
            pending[attemptId] = entry
            return false
        }
        return acked[terminalDigest] != nil
    }

    public func unacked() -> [TerminalJournalEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(pending.values)
    }

    public var isFull: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.count >= capacity
    }
}
