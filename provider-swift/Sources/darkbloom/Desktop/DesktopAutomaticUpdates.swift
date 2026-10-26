import Foundation
import ProviderCore

extension DesktopBackend {
  /// The backend owns this schedule even while Electron is closed.
  func automaticUpdates() async {
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(4 * 60 * 60)) } catch { return }
      do {
        let config = try configuration().config
        guard config.provider.autoUpdate, DaemonStateFile.read()?.processIdentity?.isCurrent() != true else { continue }
        let updater = SelfUpdater(coordinatorBaseURL: config.coordinator.url)
        switch await updater.checkForUpdate() {
        case .updateAvailable, .restartRequired:
          _ = try submit(DesktopAction(id: UUID().uuidString, action: "update"))
        default: break
        }
      } catch {
        // Busy operations retry at the next interval; the user's state is preserved.
      }
    }
  }
}
