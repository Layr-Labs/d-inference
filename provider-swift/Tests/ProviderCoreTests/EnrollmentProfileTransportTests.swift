import Foundation
import Testing
@testable import ProviderCore

@Suite("Bounded enrollment profile transport")
struct EnrollmentProfileTransportTests {
    @Test("Actual bytes stop an unfinished oversized response", arguments: [
        [String: String](),
        ["Transfer-Encoding": "chunked"],
        ["Content-Length": "8"],
        ["Content-Length": "0"],
    ])
    func overflowCancelsBeforeEOF(lengthHeaders: [String: String]) async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        stream.sendResponse(headers: profileHeaders.merging(lengthHeaders) { _, length in length })
        // Send the first overflowing byte, then keep the connection open. A
        // buffering data(for:) implementation cannot finish this request.
        let maximum = EnrollmentProfileResponse.maximumBytes
        stream.sendBody(Data(repeating: 0x41, count: maximum + 1), ending: .stall)
        try await stream.waitUntil { $0.stopped }

        do {
            _ = try await fetch.value
            Issue.record("accepted an oversized streamed body")
        } catch EnrollmentError.profileResponseTooLarge(let limit) {
            #expect(limit == maximum)
        }
        #expect(stream.snapshot.deliveredBytes == maximum + 1)
        #expect(!stream.snapshot.finished)
    }

    @Test("Oversized Content-Length cancels before receiving any body")
    func declaredOverflowCancelsAtHeaders() async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        var headers = profileHeaders
        headers["Content-Length"] = "\(EnrollmentProfileResponse.maximumBytes + 1)"
        stream.sendResponse(headers: headers)
        try await stream.waitUntil { $0.stopped }
        do {
            _ = try await fetch.value
            Issue.record("accepted oversized Content-Length")
        } catch EnrollmentError.profileResponseTooLarge(let maximum) {
            #expect(maximum == EnrollmentProfileResponse.maximumBytes)
        }
        #expect(stream.snapshot.deliveredBytes == 0)
        #expect(!stream.snapshot.finished)
    }

    @Test("Valid chunked profiles include the exact 1 MiB boundary", arguments: [
        37, EnrollmentProfileResponse.maximumBytes,
    ])
    func validChunkedBody(byteCount: Int) async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        stream.sendResponse(status: 201, headers: [
            "Content-Type": "Application/X-Apple-Aspen-Config; charset=\"binary\"",
            "Transfer-Encoding": "chunked",
        ])
        let profile = Data((0..<byteCount).map { UInt8($0 % 251) })
        stream.sendBody(profile)
        let (body, response) = try await fetch.value
        #expect(body == profile)
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        try EnrollmentProfileResponse.validate(data: body, response: response)
    }

    @Test("A stream error never returns a partial profile", arguments: [
        URLError.Code.networkConnectionLost, .timedOut,
    ])
    func streamFailure(code: URLError.Code) async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        stream.sendResponse(headers: profileHeaders)
        stream.sendBody(Data(repeating: 0x41, count: 32_768), ending: .fail(code))
        do {
            _ = try await fetch.value
            Issue.record("returned a partial profile after \(code)")
        } catch let error as URLError {
            #expect(error.code == code)
        }
        #expect(!stream.snapshot.finished)
    }

    @Test("A connection error before headers remains a transport error")
    func connectionFailure() async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        stream.fail(.cannotConnectToHost)
        do {
            _ = try await fetch.value
            Issue.record("accepted a failed connection")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        }
    }

    @Test("Caller cancellation stops a stalled request", arguments: [false, true])
    func cancellationStopsIO(afterHeaders: Bool) async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        defer { fetch.cancel() }
        try await stream.waitUntil { $0.request != nil }
        if afterHeaders {
            stream.sendResponse(headers: profileHeaders)
            stream.sendBody(Data("partial profile".utf8), ending: .stall)
            try await stream.waitUntil { $0.bodySent }
        }
        fetch.cancel()
        try await stream.waitUntil { $0.stopped }
        do {
            _ = try await fetch.value
            Issue.record("returned a cancelled profile")
        } catch is CancellationError {
            // Swift task cancellation and URLSession cancellation are both valid.
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(!stream.snapshot.finished)
    }

    @Test("An already cancelled caller never starts a request")
    func cancellationBeforeRequest() async throws {
        let stream = EnrollmentProfileHTTPStream()
        defer { stream.close() }
        let fetch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EnrollmentProfileTransport.fetchProfile(stream.request, using: stream.session)
        }
        do {
            _ = try await fetch.value
            Issue.record("started an already cancelled request")
        } catch is CancellationError {}
        #expect(stream.snapshot.request == nil)
    }

    private var profileHeaders: [String: String] {
        ["Content-Type": EnrollmentProfileResponse.supportedMediaType]
    }
}
