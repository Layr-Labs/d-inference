import ArgumentParser
import Foundation
import ProviderCore

/// What the desktop API accepts beside its first actions: how a start serves, clusters, Darkbloom Sandbox, feature
/// waitlists and local serving. Each check runs before anything starts (`DesktopAction.validate`), and its message is
/// shown to the person as it is, so none repeats a value it refuses (an account key above all).
extension DesktopAction {
  static let knownActions: Set<String> = [
    "start", "switch", "stop", "restart", "download", "remove", "settings", "link", "unlink",
    "update", "diagnose", "cancel", "cooling", "account-signin", "account-signout",
    "autopilot", "autopilot_pin", "autopilot_unpin", "autopilot_pause", "autopilot_resume",
    "autopilot_disable", "autopilot_models",
    "cluster_leave", "waitlist_join", "sandbox_pause", "sandbox_resume", "sandbox_uninstall", "sandbox_setup",
    "route", "route_key", "local_settings", "tool_setup", "update_rollback",
  ]

  /// The app's waitlist ids (`^[a-z0-9][a-z0-9-]{0,63}$`): the coordinator's catalog names them (`cluster`, `sandbox`).
  static func isWaitlistName(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    func allowed(_ scalar: Unicode.Scalar, dash: Bool) -> Bool {
      ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || (dash && scalar == "-")
    }
    guard let first = scalars.first, scalars.count <= 64, allowed(first, dash: false) else { return false }
    return scalars.dropFirst().allSatisfy { allowed($0, dash: true) }
  }

  /// At most one way to serve (`local`, `endpoint`, `network`), as `start` takes one mode flag; `solo` only for a start
  /// on a Mac that holds a pairing (`start --solo`).
  func validateServingChoice(paired: () -> Bool) throws {
    guard action == "start" || action == "switch" else { return }
    guard [local, endpoint, network].filter({ $0 == true }).count <= 1 else {
      throw ValidationError("Choose one way to serve: Only me, the Darkbloom network, or Both, me first.")
    }
    guard solo == true else { return }
    guard action == "start" else { throw ValidationError("Serving this Mac alone is a start, not a switch.") }
    guard paired() else { throw ValidationError("This Mac isn't in a two-Mac cluster: Start serving serves it alone.") }
  }

  func validateFeatureFields() throws {
    switch action {
    case "waitlist_join":
      guard let feature, Self.isWaitlistName(feature) else { throw ValidationError("Invalid waitlist") }
    case "sandbox_setup":
      try validateSandboxSetup()
    case "route":
      guard let route, LocalSettings.Route(rawValue: route) != nil else { throw ValidationError("Invalid route") }
    case "route_key":
      // `route key`'s own rules, in its words; none of them repeats the key.
      if let refusal = LocalRouterAccountKeyFormat.refusal(key ?? "") {
        throw ValidationError("Not saved: \(refusal).")
      }
    case "local_settings":
      guard me_first != nil, let minutes = me_first_idle_minutes,
        LocalSettings.meFirstIdleMinutesRange.contains(minutes)
      else { throw ValidationError("Me first needs on or off, and 1 to 120 idle minutes.") }
    case "tool_setup":
      guard let tool, IntegrationTool(rawValue: tool) != nil else { throw ValidationError("Unknown tool") }
    default:
      break
    }
  }

  /// `sandbox setup`'s own limits: Linux 0–16 and macOS 0–2 jobs at a time, not both 0, and up to four work disks, each
  /// an absolute path that stays one argument.
  private func validateSandboxSetup() throws {
    if let linux_slots, !(0...SandboxEligibility.maximumLinuxSlots).contains(linux_slots) {
      throw ValidationError("Linux jobs at a time must be from 0 to \(SandboxEligibility.maximumLinuxSlots).")
    }
    if let macos_slots, !(0...SandboxEligibility.maximumMacOSSlots).contains(macos_slots) {
      throw ValidationError("macOS jobs at a time must be from 0 to \(SandboxEligibility.maximumMacOSSlots).")
    }
    if linux_slots == 0, macos_slots == 0 {
      throw ValidationError("0 Linux and 0 macOS jobs leaves nothing to run.")
    }
    let disks = self.disks ?? []
    guard disks.count <= 4, Set(disks).count == disks.count else {
      throw ValidationError("Choose up to four different work disks.")
    }
    for disk in disks {
      guard disk.hasPrefix("/"), disk.count <= 1024,
        !disk.split(separator: "/").contains(".."),
        !disk.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        })
      else { throw ValidationError("A work disk must be an absolute path, such as /Volumes/FastSSD.") }
    }
  }

  /// The request as the API keeps it to recognize a retry with the same ID: an account key becomes its digest under
  /// this process's random key (`DesktopBackend.requestDigestKey`), so the key itself is never kept or compared.
  func retained(digest: (String) -> String) -> DesktopAction {
    var copy = self
    if let key { copy.key = digest(key) }
    return copy
  }
}
