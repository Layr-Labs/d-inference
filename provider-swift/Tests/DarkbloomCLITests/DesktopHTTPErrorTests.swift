import ArgumentParser
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing

@testable import darkbloom

/// Error-to-status mapping for the desktop control API. The live 127.0.0.1
/// checks (400/404/413/429 through the real server) are in scripts/test-desktop-api.py.
struct DesktopHTTPErrorTests {
  @Test func ninthEventStreamIsTooManyRequests() throws {
    let limiter = DesktopStreamLimiter()
    let leases = try (0..<8).map { _ in try limiter.acquire() }
    do {
      _ = try limiter.acquire()
      Issue.record("ninth stream was admitted")
    } catch {
      #expect(DesktopHTTP.errorResponse(for: error).status == .tooManyRequests)
    }
    leases[0].release()
    _ = try limiter.acquire()
  }

  @Test func validationMessagesPassThroughVerbatim() {
    let failure = DesktopHTTP.errorResponse(for: ValidationError("Choose at least one model"))
    #expect(failure.status == .badRequest)
    #expect(failure.message == "Choose at least one model")
  }

  @Test func httpErrorsKeepTheirStatusAndMessage() {
    let failure = DesktopHTTP.errorResponse(for: HTTPError(.notFound, message: "Unknown resource"))
    #expect(failure.status == .notFound)
    #expect(failure.message == "Unknown resource")
  }

  @Test func oversizedActionBodyIsContentTooLarge() async throws {
    let body = RequestBody(buffer: ByteBuffer(repeating: 0x20, count: 16_385))
    let error = await #expect(throws: (any Error).self) { _ = try await body.collect(upTo: 16_384) }
    let failure = DesktopHTTP.errorResponse(for: try #require(error))
    #expect(failure.status == .contentTooLarge)
  }

  @Test func coordinatorFailuresAreGenericBadGateway() {
    let failure = DesktopHTTP.errorResponse(for: URLError(.cannotConnectToHost))
    #expect(failure.status == .badGateway)
    #expect(failure.message == "Coordinator request failed")
  }

  @Test func malformedActionBodyIsAFixedBadRequest() {
    let error = #expect(throws: (any Error).self) {
      try DesktopHTTP.decodeAction(Data(#"{"action":"start"}"#.utf8))
    }
    let failure = DesktopHTTP.errorResponse(for: error!)
    #expect(failure.status == .badRequest)
    #expect(failure.message == "Invalid request body")
  }

  @Test func internalFailuresDoNotLeakTheirDescription() {
    let failure = DesktopHTTP.errorResponse(for: CocoaError(.fileReadNoPermission))
    #expect(failure.status == .internalServerError)
    #expect(failure.message == "Internal error")
  }
}
