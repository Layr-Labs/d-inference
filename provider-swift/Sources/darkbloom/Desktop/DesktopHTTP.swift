import ArgumentParser
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ProviderCore

struct DesktopHTTP: HTTPResponder {
  typealias Context = BasicRequestContext
  let backend: DesktopBackend
  let token: String
  var hardware = DesktopHardware.live
  let streams = DesktopStreamLimiter()

  static func authorized(header: String?, token: String, origin: String?, host: String?) -> Bool {
    guard origin == nil, let host,
      let header, !token.isEmpty
    else { return false }
    let parts = host.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.first == "127.0.0.1",
      parts.count == 1
        || (parts.count == 2 && Int(parts[1]).map { (1...65535).contains($0) } == true)
    else { return false }
    let a = Array(header.utf8)
    let b = Array("Bearer \(token)".utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  func respond(to request: Request, context: Context) async throws -> Response {
    guard
      Self.authorized(
        header: request.headers[.authorization], token: token, origin: request.headers[.origin],
        host: request.head.authority)
    else {
      return try json(.dict(["error": .string("Unauthorized local client")]), status: .unauthorized)
    }
    do {
      let path = request.uri.path
      if request.method == .get, path == "/control/v1/events" {
        let lease = try streams.acquire()
        return Response(
          status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-store"],
          body: .init { writer in
            defer { lease.release() }
            // Full snapshots make every reconnect an explicit resync; no deltas can be lost.
            for _ in 0..<30 {
              let snapshot = try await backend.state()
              let data = try JSONEncoder().encode(snapshot)
              try await writer.write(
                ByteBuffer(
                  string: "event: state\ndata: \(String(decoding: data, as: UTF8.self))\n\n"))
              try await Task.sleep(for: .seconds(2))
            }
            try await writer.finish(nil)
          })
      }
      if request.method == .get, path == "/control/v1/hardware/events" {
        return hardware.events(lease: try streams.acquire())
      }
      if request.method == .get, path == "/control/v1/hardware" {
        return try json(
          await hardware.resource(peakBandwidthGbps: await backend.peakMemoryBandwidthGbps()))
      }
      if request.method == .get, path.hasPrefix("/control/v1/") {
        return try json(try await backend.resource(String(path.dropFirst("/control/v1/".count))))
      }
      if request.method == .post, path == "/control/v1/actions" {
        guard request.headers[.contentType]?.split(separator: ";").first == "application/json"
        else {
          return try json(.dict(["error": .string("JSON required")]), status: .unsupportedMediaType)
        }
        let bytes = try await request.body.collect(upTo: 16_384)
        let action = try Self.decodeAction(Data(bytes.readableBytesView))
        return try json(try .encoded(await backend.submit(action)), status: .accepted)
      }
      return try json(.dict(["error": .string("Unknown route")]), status: .notFound)
    } catch {
      let failure = Self.errorResponse(for: error)
      return try json(.dict(["error": .string(failure.message)]), status: failure.status)
    }
  }

  /// Only the client's own body is a client error (400); the renderer shows the
  /// message, so it is fixed rather than Swift's coding-path text.
  static func decodeAction(_ data: Data) throws -> DesktopAction {
    do { return try JSONDecoder().decode(DesktopAction.self, from: data) } catch {
      throw ValidationError("Invalid request body")
    }
  }

  /// Validation messages are user-facing and pass through verbatim; HTTP errors
  /// (including the body limit's 413) keep their status. Coordinator and
  /// internal failures get a generic message.
  static func errorResponse(for error: any Error) -> (status: HTTPResponse.Status, message: String)
  {
    switch error {
    case let error as HTTPError: return (error.status, error.body ?? error.status.reasonPhrase)
    case let error as any HTTPResponseError: return (error.status, error.status.reasonPhrase)
    case let error as ValidationError: return (.badRequest, error.message)
    case is URLError: return (.badGateway, "Coordinator request failed")
    default: return (.internalServerError, "Internal error")
    }
  }

  private func json(_ value: JSONValue, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
      status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(bytes: data)))
  }
}

final class DesktopStreamLimiter: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  func acquire() throws -> Lease {
    try lock.withLock {
      guard active < 8 else { throw HTTPError(.tooManyRequests) }
      active += 1
      return Lease(self)
    }
  }
  private func remove() { lock.withLock { active -= 1 } }
  final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: DesktopStreamLimiter?
    init(_ owner: DesktopStreamLimiter) { self.owner = owner }
    func release() {
      lock.withLock {
        owner?.remove()
        owner = nil
      }
    }
    deinit { release() }
  }
}
