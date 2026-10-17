import Foundation

protocol DistributedHTTPResponseProviding: Sendable {
    func begin() throws -> DistributedHTTPResponse
}

extension DistributedHTTPResponses: DistributedHTTPResponseProviding {}

/// Stable listener route. It replaces registries; it never reopens old tickets.
final class DistributedHTTPResponseRouter: DistributedHTTPResponseProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: DistributedHTTPResponses?
    private var closed = false

    func publish(_ registry: DistributedHTTPResponses) throws {
        try lock.withLock {
            guard !closed, current == nil else {
                throw DistributedLocalServerError.startupInterrupted
            }
            current = registry
        }
    }

    func withdraw(_ registry: DistributedHTTPResponses) {
        lock.withLock {
            registry.closeAdmissions()
            if current === registry { current = nil }
        }
    }

    func close() {
        lock.withLock {
            closed = true
            current?.closeAdmissions()
            current = nil
        }
    }

    func begin() throws -> DistributedHTTPResponse {
        try lock.withLock {
            guard !closed, let current else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response is unavailable")
            }
            return try current.begin()
        }
    }
}
