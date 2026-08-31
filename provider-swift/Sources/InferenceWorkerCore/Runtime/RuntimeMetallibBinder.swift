import CryptoKit
import Darwin
import Foundation
import ProviderMetallibControl
import os

private let metallibLogger = Logger(subsystem: "io.darkbloom.provider.inference-worker", category: "metallib")

private enum RuntimeMetallibBindingError: Error {
    case sourceUnavailable
    case snapshotCreateFailed
    case snapshotUnlinkFailed
}

public struct RuntimeMetallibBindingInfo: Sendable, Equatable {
    public let sourceURL: URL
    public let loaderPath: String
    public let digest: String
}

private final class RuntimeMetallibSnapshot: @unchecked Sendable {
    let fileDescriptor: Int32
    let sourceURL: URL
    let digest: String
    let loaderPath: String

    init(fileDescriptor: Int32, sourceURL: URL, digest: String) {
        self.fileDescriptor = fileDescriptor
        self.sourceURL = sourceURL
        self.digest = digest
        loaderPath = "/dev/fd/\(fileDescriptor)"
    }

    deinit { Darwin.close(fileDescriptor) }
}

private final class RuntimeMetallibBinder: @unchecked Sendable {
    private let lock = NSLock()
    private var bound: RuntimeMetallibSnapshot?

    func bind(from explicitURL: URL?) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let requestedURL = explicitURL ?? locateRuntimeMetallib() else { return nil }
        let sourceURL = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        if let bound {
            guard bound.sourceURL == sourceURL else { return nil }
            guard let candidate = try? makeSnapshot(sourceURL: sourceURL), candidate.digest == bound.digest else {
                return nil
            }
            return bound.digest
        }

        do {
            let snapshot = try makeSnapshot(sourceURL: sourceURL)
            snapshot.loaderPath.withCString { darkbloom_mlx_set_metallib_path($0) }
            bound = snapshot
            return snapshot.digest
        } catch {
            metallibLogger.error("Failed to bind approved MLX metallib")
            return nil
        }
    }

    func bindingInfo() -> RuntimeMetallibBindingInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let bound else { return nil }
        return RuntimeMetallibBindingInfo(
            sourceURL: bound.sourceURL,
            loaderPath: bound.loaderPath,
            digest: bound.digest
        )
    }
}

private let runtimeMetallibBinder = RuntimeMetallibBinder()

private func makeSnapshot(sourceURL: URL) throws -> RuntimeMetallibSnapshot {
    guard let source = FileHandle(forReadingAtPath: sourceURL.path) else {
        throw RuntimeMetallibBindingError.sourceUnavailable
    }
    defer { try? source.close() }

    var template = Array((NSTemporaryDirectory() + "darkbloom-mlx-metallib.XXXXXX").utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
    guard descriptor >= 0 else { throw RuntimeMetallibBindingError.snapshotCreateFailed }
    let temporaryPath = String(cString: template)
    guard unlink(temporaryPath) == 0 else {
        Darwin.close(descriptor)
        throw RuntimeMetallibBindingError.snapshotUnlinkFailed
    }
    var retainDescriptor = false
    defer { if !retainDescriptor { Darwin.close(descriptor) } }

    let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var hasher = SHA256()
    while true {
        let bytes = try source.read(upToCount: 1024 * 1024) ?? Data()
        if bytes.isEmpty { break }
        try destination.write(contentsOf: bytes)
        hasher.update(data: bytes)
    }
    try destination.synchronize()
    _ = fchmod(descriptor, S_IRUSR)
    try destination.seek(toOffset: 0)
    retainDescriptor = true
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return RuntimeMetallibSnapshot(
        fileDescriptor: descriptor,
        sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
        digest: digest
    )
}

public func bindRuntimeMetallibForMLX(from explicitURL: URL? = nil) -> String? {
    runtimeMetallibBinder.bind(from: explicitURL)
}

public func runtimeMetallibBindingInfo() -> RuntimeMetallibBindingInfo? {
    runtimeMetallibBinder.bindingInfo()
}

public func metallibHash() -> String? {
    runtimeMetallibBinder.bindingInfo()?.digest
}
