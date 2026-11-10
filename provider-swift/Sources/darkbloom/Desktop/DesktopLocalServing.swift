import ArgumentParser
import Crypto
import Foundation
import ProviderCore

/// How this Mac serves its owner (`[local]` in provider.toml) for the app: `Snapshot.local`, and the actions that change
/// it as the CLI's own commands do (`route`, `route key`, `[local] me_first`, `start --opencode`/`--hermes`).
extension DesktopBackend {
  /// Whether an account key is saved is read again after this long: it asks the Keychain (`Start.accountKeySaved`).
  static let accountKeyReadInterval: TimeInterval = 30

  /// `Snapshot.local`, from `[local]` as the CLI resolves it (`LocalSettings`): the saved `mode` (null before the first
  /// choice), me first and its idle minutes, where your requests go (`resolvedRoute`, which follows whether an account
  /// key is saved), whether one is saved (never the key), this Mac's local API port and bind address, and how long
  /// Darkbloom stays paused for you when a fresh provider says so (`pausedUntil`).
  func localServingSnapshot(_ settings: LocalSettings?, daemon: DaemonState?, fresh: Bool, now: Date) -> JSONValue {
    Self.localServing(settings, keySaved: accountKeySaved(now: now), meFirst: fresh ? daemon?.meFirst : nil)
  }

  static func localServing(_ settings: LocalSettings?, keySaved: Bool, meFirst: MeFirstSnapshot?) -> JSONValue {
    let settings = settings ?? LocalSettings()
    return .dict([
      "mode": settings.mode.map { .string($0.rawValue) } ?? .null,
      "me_first": .bool(settings.meFirst != false),
      "me_first_idle_minutes": .int(Int64(settings.resolvedMeFirstIdleMinutes)),
      "route": .string(settings.resolvedRoute(accountKeySaved: keySaved).rawValue),
      "route_key": .bool(keySaved),
      "port": settings.port.map { .int(Int64($0)) } ?? .null,
      "bind": .string(settings.resolvedBind),
      "paused_until": pausedUntil(meFirst),
    ])
  }

  /// When Darkbloom comes back if the owner stays idle, in Unix seconds: only while a running provider says it is
  /// paused for the owner and knows when it resumes (`MeFirstSnapshot.resumesAtMs`, which a request of the owner's still
  /// running leaves unknown); else null.
  static func pausedUntil(_ snapshot: MeFirstSnapshot?) -> JSONValue {
    guard let snapshot, snapshot.paused, snapshot.sinceMs != nil, snapshot.localRequestsInFlight == 0,
      let resumes = snapshot.resumesAtMs
    else { return .null }
    return .number(Double(resumes) / 1_000)
  }

  /// Whether the local router's account key is saved, as `darkbloom status` asks it (`Start.accountKeySaved`), read again
  /// after `accountKeyReadInterval` and after a `route_key` action.
  func accountKeySaved(now: Date) -> Bool {
    if let read = accountKeyRead, now.timeIntervalSince(read.at) < Self.accountKeyReadInterval { return read.saved }
    let saved = Start.accountKeySaved()
    accountKeyRead = (now, saved)
    return saved
  }

  /// `local_settings`: saves `[local] me_first` and `me_first_idle_minutes` with the CLI's own `[local]` writer
  /// (`setLocalSettings`: under the config lock, other keys kept), as `start --me-first`, `--no-me-first` and
  /// `--me-first-idle` save them. A running provider reads them when it starts (`ProviderLoopConfig.meFirstIdle`), so
  /// they apply from its next start.
  func executeLocalSettings(_ request: DesktopAction) throws {
    let meFirst = request.me_first!
    let minutes = request.me_first_idle_minutes!
    let saved = try setLocalSettings(configPath: configPath) { settings in
      settings.meFirst = meFirst
      settings.meFirstIdleMinutes = minutes
    }
    let head = saved.changed ? "Saved." : "Already saved."
    let running = DaemonStateFile.read()?.processIdentity?.isCurrent() == true
    complete(
      request.id, code: 0,
      message: running ? "\(head) Restart serving to use it now." : head)
  }

  /// `route_key`'s key for `route key --stdin`: one line on standard input, never an argument.
  static func routeKeyInput(_ request: DesktopAction) -> Data? {
    guard request.action == "route_key", let key = request.key else { return nil }
    return Data((key + "\n").utf8)
  }

  /// `route key`'s output says nothing that contains the key (`RouteKeyFlow`); an echo of it would still never reach the
  /// operation or its journal.
  static func withoutKey(_ output: String, request: DesktopAction) -> String {
    guard request.action == "route_key", let key = request.key, !key.isEmpty else { return output }
    return output.replacingOccurrences(of: key, with: "[key]")
  }

  /// A per-process key for the digest that stands in for an account key in `requests` (`DesktopAction.retained`).
  static let requestDigestKey = SymmetricKey(size: .bits256)

  static func requestDigest(_ value: String) -> String {
    "hmac-sha256:" + HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: requestDigestKey)
      .map { String(format: "%02x", $0) }.joined()
  }
}
