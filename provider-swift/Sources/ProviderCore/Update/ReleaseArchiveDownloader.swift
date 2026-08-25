import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ReleaseArchiveDownloadError: LocalizedError, CustomStringConvertible {
    let message: String

    var errorDescription: String? { message }
    var description: String { message }
}

struct ReleaseArchiveDownloadBudget {
    let maximumBytes: UInt64
    private(set) var receivedBytes: UInt64 = 0

    func validateExpectedContentLength(_ length: Int64) throws {
        guard length < 0 || UInt64(length) <= maximumBytes else {
            throw limitError()
        }
    }

    mutating func consume(_ count: Int) throws {
        let (next, overflow) = receivedBytes.addingReportingOverflow(
            UInt64(count)
        )
        guard !overflow, next <= maximumBytes else {
            throw limitError()
        }
        receivedBytes = next
    }

    private func limitError() -> ReleaseArchiveDownloadError {
        ReleaseArchiveDownloadError(
            message: "release archive exceeds the \(maximumBytes)-byte "
                + "compressed-size limit"
        )
    }
}

enum ReleaseArchiveDownloader {
    static func download(
        from url: URL,
        using session: URLSession,
        maximumBytes: UInt64
    ) async throws -> (URL, HTTPURLResponse) {
        let delegate = try ReleaseArchiveDownloadDelegate(
            maximumBytes: maximumBytes
        )
        let task = session.dataTask(with: url)
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (
                    continuation:
                        CheckedContinuation<(URL, HTTPURLResponse), Error>
                ) in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class ReleaseArchiveDownloadDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let destination: URL
    private var writer: FileHandle?
    private var budget: ReleaseArchiveDownloadBudget
    private var response: HTTPURLResponse?
    private var terminalError: Error?
    private var handedOff = false

    private let continuationLock = NSLock()
    private var continuation:
        CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var resumed = false

    init(maximumBytes: UInt64) throws {
        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("darkbloom-release.XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw Self.posixError("create private release download")
        }
        let path = String(cString: template)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = Self.posixError(
                "mark private release download close-on-exec"
            )
            _ = close(descriptor)
            _ = unlink(path)
            throw error
        }

        destination = URL(fileURLWithPath: path)
        writer = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        budget = ReleaseArchiveDownloadBudget(maximumBytes: maximumBytes)
        super.init()
    }

    deinit {
        try? writer?.close()
        if !handedOff {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    func attach(
        _ continuation:
            CheckedContinuation<(URL, HTTPURLResponse), Error>
    ) {
        continuationLock.lock()
        self.continuation = continuation
        continuationLock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler:
            @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            terminalError = ReleaseArchiveDownloadError(
                message: "release download returned an unexpected response"
            )
            completionHandler(.cancel)
            return
        }
        guard httpResponse.statusCode == 200 else {
            terminalError = ReleaseArchiveDownloadError(
                message: "release download returned HTTP "
                    + "\(httpResponse.statusCode)"
            )
            completionHandler(.cancel)
            return
        }

        do {
            try budget.validateExpectedContentLength(
                httpResponse.expectedContentLength
            )
            self.response = httpResponse
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard terminalError == nil, let writer else { return }
        do {
            try budget.consume(data.count)
            try writer.write(contentsOf: data)
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        do {
            try writer?.close()
            writer = nil
        } catch {
            terminalError = terminalError ?? error
        }

        if let terminalError {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(terminalError))
            return
        }
        if let error {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(error))
            return
        }
        guard let response else {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(ReleaseArchiveDownloadError(
                message: "release download completed without an HTTP response"
            )))
            return
        }

        handedOff = true
        finish(.success((destination, response)))
    }

    private func finish(
        _ result: Result<(URL, HTTPURLResponse), Error>
    ) {
        continuationLock.lock()
        guard !resumed, let continuation else {
            continuationLock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        continuationLock.unlock()

        switch result {
        case .success(let download):
            continuation.resume(returning: download)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func posixError(
        _ operation: String
    ) -> ReleaseArchiveDownloadError {
        ReleaseArchiveDownloadError(
            message: "\(operation): \(String(cString: strerror(errno)))"
        )
    }
}
