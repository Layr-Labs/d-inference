import Darwin
import Dispatch
import Foundation
@testable import SandboxRuntime

enum PolicyInitializationOutcome: Equatable, Sendable {
    case initialized
    case rejected(SandboxCapacityError)
    case unexpected(String)
}

func policyInitializationOutcome(
    _ arbiter: SandboxHostCapacityArbiter
) -> PolicyInitializationOutcome {
    do {
        _ = try arbiter.initialize()
        return .initialized
    } catch let error as SandboxCapacityError {
        return .rejected(error)
    } catch {
        return .unexpected(String(describing: error))
    }
}

final class OneShotBlockingDirectorySynchronization: @unchecked Sendable {
    private let stateLock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private var hasBlocked = false

    func synchronizationError(for descriptor: Int32) -> Int32? {
        stateLock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        stateLock.unlock()
        if shouldBlock {
            blocked.signal()
            proceed.wait()
        }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return nil
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 5) == .success
    }

    func resume() {
        proceed.signal()
    }
}

final class OneShotBlockingStorageAvailability: @unchecked Sendable {
    private let stateLock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let value: UInt64
    private var armed = false
    private var hasBlocked = false

    init(_ value: UInt64) {
        self.value = value
    }

    func arm() {
        stateLock.lock()
        armed = true
        stateLock.unlock()
    }

    func available() -> UInt64 {
        stateLock.lock()
        let shouldBlock = armed && !hasBlocked
        if shouldBlock {
            hasBlocked = true
        }
        stateLock.unlock()
        if shouldBlock {
            blocked.signal()
            proceed.wait()
        }
        return value
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 5) == .success
    }

    func resume() {
        proceed.signal()
    }
}

final class LeaseOperationLockContentionProbe: @unchecked Sendable {
    private let stateLock = NSLock()
    private let observed = DispatchSemaphore(value: 0)
    private var observedLock: String?

    var firstObservedLock: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return observedLock
    }

    func observe(lockName: String) {
        stateLock.lock()
        let isFirstObservation = observedLock == nil
        if isFirstObservation {
            observedLock = lockName
        }
        stateLock.unlock()
        if isFirstObservation {
            observed.signal()
        }
    }

    func waitUntilObserved() -> Bool {
        observed.wait(timeout: .now() + 5) == .success
    }
}
