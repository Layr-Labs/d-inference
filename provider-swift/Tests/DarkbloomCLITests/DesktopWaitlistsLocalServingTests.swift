import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The app's waitlists go through the CLI's own client and words (a fake coordinator's answers here), and
/// `Snapshot.local` reads `[local]` as the CLI resolves it. No coordinator, Keychain or provider is touched.
struct DesktopWaitlistsLocalServingTests {
  static let coordinator = "https://coordinator.example"

  static func place(_ feature: String, _ status: FeatureWaitlistPlace.Status, position: Int? = nil) -> FeatureWaitlistPlace {
    FeatureWaitlistPlace(
      feature: feature, title: feature == "sandbox" ? "Darkbloom Sandbox" : "Clusters", summary: "Summary",
      startCommand: "darkbloom \(feature)", status: status, position: position,
      requestedAt: Date(timeIntervalSince1970: 1_762_560_000), decidedAt: nil)
  }

  static func access(
    list: Result<FeatureWaitlists, FeatureWaitlistProblem>,
    join: @escaping @Sendable (String) -> FeatureWaitlistLookup = { _ in .failure(.unavailable("not asked")) }
  ) -> FeatureWaitlistAccess {
    FeatureWaitlistAccess(
      coordinator: coordinator, waitlists: { list }, place: { _ in .failure(.unavailable("not asked")) },
      join: { join($0) })
  }

  @Test func theListIsTheCLIsJSONInTheCoordinatorsOrder() async {
    let lists = FeatureWaitlists(data: [Self.place("cluster", .approved), Self.place("sandbox", .waitlisted, position: 7)])
    let value = await DesktopBackend.readWaitlists(Self.access(list: .success(lists)))
    let data = value.field("data").values
    #expect(data.map { $0.field("feature").text } == ["cluster", "sandbox"])
    #expect(data[1].field("status").text == "waitlisted")
    #expect(data[1].field("position") == .int(7))
    #expect(data[1].field("start_command").text == "darkbloom sandbox")
    #expect(data[1].field("requested_at").text == "2025-11-08T00:00:00Z")
    #expect(value.field("error") == .null)
    #expect(value.field("code") == .null)
  }

  @Test(arguments: [
    (FeatureWaitlistProblem.needsLogin, "login", "Link this Mac to your Darkbloom account first: darkbloom login"),
    (.refused("token revoked"), "login",
     "https://coordinator.example refused this account: HTTP 403: token revoked. Link this Mac to your Darkbloom account again: darkbloom login"),
    (.notOffered, "none", "https://coordinator.example has no waitlists yet, so there is nothing to join there."),
    (.unavailable("no answer within 10 seconds"), "unavailable",
     "Could not reach the waitlists at https://coordinator.example: no answer within 10 seconds"),
  ] as [(FeatureWaitlistProblem, String, String)])
  func noListSaysWhyInTheCLIsWordsWithWhatToDo(problem: FeatureWaitlistProblem, code: String, error: String) async {
    let value = await DesktopBackend.readWaitlists(Self.access(list: .failure(problem)))
    #expect(value.field("data") == .array([]))
    #expect(value.field("code").text == code)
    #expect(value.field("error").text == error)
  }

  @Test func localServingResolvesLocalAsTheCLIDoes() {
    let none = DesktopBackend.localServing(nil, keySaved: false, meFirst: nil)
    #expect(none == .dict([
      "mode": .null, "me_first": .bool(true), "me_first_idle_minutes": .int(2), "route": .string("this-mac"),
      "route_key": .bool(false), "port": .null, "bind": .string("127.0.0.1"), "paused_until": .null,
    ]))
    // With a key saved and no route chosen, requests go on to your other Macs (`resolvedRoute`).
    #expect(DesktopBackend.localServing(nil, keySaved: true, meFirst: nil).field("route").text == "my-macs")
    let saved = LocalSettings(mode: .both, meFirst: false, meFirstIdleMinutes: 15, route: .myMacsFirst, port: 8007,
                              bind: "0.0.0.0")
    let value = DesktopBackend.localServing(saved, keySaved: true, meFirst: nil)
    #expect(value.field("mode").text == "both")
    #expect(value.field("me_first").flag == false)
    #expect(value.field("me_first_idle_minutes") == .int(15))
    #expect(value.field("route").text == "my-macs-first")
    #expect(value.field("route_key").flag == true)
    #expect(value.field("port") == .int(8007))
    #expect(value.field("bind").text == "0.0.0.0")
  }

  @Test func pausedUntilOnlyWhenTheProviderKnowsWhen() {
    let idle = MeFirstSnapshot(idleMs: 120_000, paused: true, sinceMs: 1_000, lastUseMs: 2_000, resumesAtMs: 122_000)
    #expect(DesktopBackend.pausedUntil(idle) == .number(122))
    var running = idle
    running.localRequestsInFlight = 1
    running.resumesAtMs = nil
    #expect(DesktopBackend.pausedUntil(running) == .null)
    #expect(DesktopBackend.pausedUntil(MeFirstSnapshot(idleMs: 120_000, paused: false)) == .null)
    #expect(DesktopBackend.pausedUntil(nil) == .null)
  }
}
