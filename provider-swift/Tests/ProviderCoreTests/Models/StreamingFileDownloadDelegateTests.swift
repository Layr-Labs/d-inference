import Foundation
import Testing
@testable import ProviderCore

@Suite("Streaming download completion ownership", .serialized)
struct StreamingFileDownloadDelegateTests {
    @Test("a suspended URLSession task can cancel before its waiter attaches")
    func cancellationBeforeAttachment() throws {
        let fixture = try DownloadCompletionFixture()
        defer { fixture.close() }
        let observer = DownloadCompletionObserver(fixture.delegate)
        fixture.task.delegate = observer
        // Never resume or contact a server. Foundation still delivers completion
        // for cancellation of a suspended task, as streamDownload's onCancel can.
        fixture.task.cancel()
        try #require(observer.completed.wait(timeout: .now() + 5) == .success)
        #expect(throws: CancellationError.self) { try fixture.awaitOutcome() }
        #expect(!FileManager.default.fileExists(atPath: fixture.partial.path))
    }

    @Test("completion survives either attachment order", arguments: [false, true])
    func completionOrdering(completesFirst: Bool) throws {
        let fixture = try DownloadCompletionFixture()
        defer { fixture.close() }
        let complete: @Sendable () -> Void = {
            fixture.delegate.urlSession(fixture.session, task: fixture.task, didCompleteWithError: nil)
        }
        if completesFirst { complete() }
        let outcome = try fixture.awaitOutcome { if !completesFirst { complete() } }
        guard case .success = outcome else {
            Issue.record("successful completion changed outcome")
            return
        }
    }

    @Test("the first terminal error wins", arguments: [false, true])
    func duplicateCompletion(completesFirst: Bool) throws {
        let fixture = try DownloadCompletionFixture()
        defer { fixture.close() }
        let complete: @Sendable () -> Void = {
            fixture.delegate.urlSession(fixture.session, task: fixture.task,
                                        didCompleteWithError: URLError(.networkConnectionLost))
            fixture.delegate.urlSession(fixture.session, task: fixture.task,
                                        didCompleteWithError: URLError(.cancelled))
        }
        if completesFirst { complete() }
        do {
            _ = try fixture.awaitOutcome { if !completesFirst { complete() } }
            Issue.record("transport failure unexpectedly succeeded")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
    }

    @Test("cancellation closes the writer and preserves the received prefix")
    func cancellationPreservesPartialFile() throws {
        let fixture = try DownloadCompletionFixture()
        defer { fixture.close() }
        let bytes = Data("resumable-prefix".utf8)
        let response = try #require(HTTPURLResponse(url: fixture.task.originalRequest!.url!,
                                                  statusCode: 200, httpVersion: nil, headerFields: nil))
        fixture.delegate.urlSession(fixture.session, dataTask: fixture.task, didReceive: response) {
            #expect($0 == .allow)
        }
        fixture.delegate.urlSession(fixture.session, dataTask: fixture.task, didReceive: bytes)
        #expect(throws: CancellationError.self) {
            try fixture.awaitOutcome {
                fixture.delegate.urlSession(fixture.session, task: fixture.task,
                                            didCompleteWithError: URLError(.cancelled))
            }
        }
        #expect(try Data(contentsOf: fixture.partial) == bytes)
        // A late data callback must not keep writing after completion.
        fixture.delegate.urlSession(fixture.session, dataTask: fixture.task, didReceive: Data([0]))
        #expect(try Data(contentsOf: fixture.partial) == bytes)
    }

    @Test("attachment racing completion never loses a waiter")
    func concurrentAttachment() throws {
        for _ in 0..<100 {
            let fixture = try DownloadCompletionFixture()
            defer { fixture.close() }
            DispatchQueue.global().async {
                fixture.delegate.urlSession(fixture.session, task: fixture.task,
                                            didCompleteWithError: URLError(.cancelled))
            }
            #expect(throws: CancellationError.self) { try fixture.awaitOutcome() }
        }
    }
}

private final class DownloadCompletionFixture: @unchecked Sendable {
    let directory: URL
    let partial: URL
    let delegate: StreamingFileDownloadDelegate
    let session = URLSession(configuration: .ephemeral)
    let task: URLSessionDataTask

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-completion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        partial = directory.appendingPathComponent("model.part")
        delegate = StreamingFileDownloadDelegate(partial: partial, existingBytes: 0,
                                                label: "model", onChunk: nil)
        task = session.dataTask(with: URL(string: "https://download.invalid/model")!)
    }

    func close() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // Bound regressions instead of hanging the test runner on a lost continuation.
    // On the broken implementation, one extra callback releases the stranded
    // waiter after recording the failure; the fixed delegate ignores duplicates.
    func awaitOutcome(afterAttach: @escaping @Sendable () -> Void = {}) throws
        -> StreamingFileDownloadDelegate.Outcome
    {
        let waiter = DownloadOutcomeWaiter()
        Task.detached { [self] in
            do {
                let outcome = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<StreamingFileDownloadDelegate.Outcome, Error>) in
                    delegate.attach(continuation)
                    afterAttach()
                }
                waiter.finish(.success(outcome))
            } catch { waiter.finish(.failure(error)) }
        }
        if waiter.completed.wait(timeout: .now() + 2) != .success {
            Issue.record("terminal callback was lost before continuation attachment")
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            try #require(waiter.completed.wait(timeout: .now() + 2) == .success)
        }
        return try #require(waiter.result).get()
    }
}

private final class DownloadOutcomeWaiter: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Result<StreamingFileDownloadDelegate.Outcome, Error>?
    var result: Result<StreamingFileDownloadDelegate.Outcome, Error>? { lock.withLock { stored } }
    func finish(_ result: Result<StreamingFileDownloadDelegate.Outcome, Error>) {
        lock.withLock { stored = result }
        completed.signal()
    }
}

private final class DownloadCompletionObserver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    let delegate: StreamingFileDownloadDelegate
    init(_ delegate: StreamingFileDownloadDelegate) { self.delegate = delegate }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        delegate.urlSession(session, task: task, didCompleteWithError: error)
        completed.signal()
    }
}
