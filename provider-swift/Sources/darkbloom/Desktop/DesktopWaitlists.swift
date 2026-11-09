import ArgumentParser
import Crypto
import Foundation
import ProviderCore

/// Feature waitlists for the app, through the CLI's own client with this Mac's `darkbloom login` token, as `darkbloom
/// waitlist` asks them (`FeatureWaitlistAccess.live`): the coordinator of the API's provider config, HTTPS (or plain
/// HTTP to this Mac only), no redirects, 10 seconds a call.
extension DesktopBackend {
  static let waitlistsReadKey = "waitlists"

  /// `GET /control/v1/waitlists`: `darkbloom waitlist --json` as `{data}`, or `{data: [], error, code}` with the CLI's
  /// words for why there is no list. Cached 30 s per coordinator and login token, like the other account reads; a
  /// finished `waitlist_join`, `link` or `unlink` makes the next read ask again.
  func waitlists() async -> JSONValue {
    let access = FeatureWaitlistAccess.live(configPath: configPath)
    // The token only keys the cache, as a digest; it never leaves the client.
    let identity = SHA256.hash(data: Data("\(access.coordinator)\n\(AuthTokenStore.load() ?? "")".utf8))
      .map { String(format: "%02x", $0) }.joined()
    return await sharedRead("\(Self.waitlistsReadKey)\n\(identity)", ttl: 30) {
      await Self.readWaitlists(access)
    }
  }

  static func readWaitlists(_ access: FeatureWaitlistAccess) async -> JSONValue {
    switch await access.waitlists() {
    case .success(let waitlists):
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(waitlists),
        let document = try? JSONDecoder().decode(JSONValue.self, from: data)
      else { return waitlistsProblem(.unavailable("the coordinator's answer could not be read"), access: access) }
      return document
    case .failure(let problem):
      return waitlistsProblem(problem, access: access)
    }
  }

  /// No list, and what the person can do about it: `login` (401 or 403: link this Mac's account), `none` (404: this
  /// coordinator has no waitlists) or `unavailable` (anything else), with the CLI's sentence (`FeatureWaitlistView`).
  static func waitlistsProblem(_ problem: FeatureWaitlistProblem, access: FeatureWaitlistAccess) -> JSONValue {
    let code: String
    switch problem {
    case .needsLogin, .refused: code = "login"
    case .notOffered: code = "none"
    case .unavailable: code = "unavailable"
    }
    let view = FeatureWaitlistView(cli: BuildEnvironment.current.cliName, coordinator: access.coordinator)
    // One sentence after another: the problem, then what to do when the CLI says it on a line of its own.
    let lines = view.problem(problem).map { $0.trimmingCharacters(in: .whitespaces) }
    let error = lines.enumerated().map { index, line in
      index < lines.count - 1 && !(line.last.map { ".:!?".contains($0) } ?? true) ? line + "." : line
    }.joined(separator: " ")
    return .dict(["data": .array([]), "error": .string(error), "code": .string(code)])
  }
}
