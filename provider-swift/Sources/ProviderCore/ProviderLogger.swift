import Foundation
#if canImport(os)
import os
#endif

/// Unified logger that uses os.Logger on macOS. Dynamic strings are private by
/// default: inference-adjacent callers must use bounded messages, and this
/// prevents an accidental interpolation from becoming public unified-log data.
/// This is defense in depth, not a boundary against a malicious host owner.
/// Internal access so the
/// `ProviderLoop` companion extension files (e.g. `+SSEParser.swift`) can re-use
/// it for their file-scope loggers — `parseStreamChunk` is a `static` method and
/// can't reach the per-instance logger on the actor.
struct ProviderLogger: Sendable {
    #if canImport(os)
    private let osLogger: os.Logger
    #endif
    private let category: String

    init(subsystem: String, category: String) {
        self.category = category
        #if canImport(os)
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        #endif
    }

    func info(_ message: String) {
        #if canImport(os)
        osLogger.info("\(message, privacy: .private)")
        #else
        print("[\(category)] INFO: \(message)")
        #endif
    }

    func warning(_ message: String) {
        #if canImport(os)
        osLogger.warning("\(message, privacy: .private)")
        #else
        print("[\(category)] WARN: \(message)")
        #endif
    }

    func error(_ message: String) {
        #if canImport(os)
        osLogger.error("\(message, privacy: .private)")
        #else
        print("[\(category)] ERROR: \(message)")
        #endif
    }
}
