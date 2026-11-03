import Testing
import ProviderCore
@testable import darkbloom

/// The Models page shows what the live registration carries, not only the selection.
@Test func modelRegistrationNamesWhatTheLiveRegistrationCarries() {
  let registered = DaemonState.RegisteredModels(models: ["served"], autopilotInventory: ["cached"])
  #expect(DesktopBackend.modelRegistration("served", registered: registered) == .string("routable"))
  #expect(DesktopBackend.modelRegistration("cached", registered: registered) == .string("autopilot"))
  #expect(DesktopBackend.modelRegistration("selected", registered: registered) == .string("none"))
  // No live registration, or an older daemon: unknown, never "none".
  #expect(DesktopBackend.modelRegistration("served", registered: nil) == .null)
}
