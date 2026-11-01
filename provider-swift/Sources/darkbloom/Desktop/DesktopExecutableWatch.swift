import Darwin
import Foundation

extension DesktopBackend {
  static let unknownExecutableStamp = "unknown"

  /// Identity of the file at `path` (inode, size, modification date). The
  /// updater installs by atomic rename/exchange, so a replacement changes it.
  static func executableStamp(at path: String?) -> String {
    guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let inode = attributes[.systemFileNumber], let size = attributes[.size],
      let modified = attributes[.modificationDate]
    else { return unknownExecutableStamp }
    return "\(inode):\(size):\(modified)"
  }

  /// Stamp of this process's executable path.
  static func currentExecutableStamp() -> String {
    executableStamp(at: try? FanServiceManager().currentExecutableURL().path)
  }

  /// An unreadable stamp never restarts the API; a running operation defers it.
  static func shouldRestartForReplacedExecutable(
    startup: String, current: String, hasRunningOperation: Bool
  ) -> Bool {
    startup != unknownExecutableStamp && current != unknownExecutableStamp
      && current != startup && !hasRunningOperation
  }

  /// Exit once the executable was replaced out of band (terminal `update`,
  /// provider self-update, the app's repair path) so launchd's KeepAlive
  /// relaunches the replacement. Checked every `interval`.
  func exitWhenExecutableReplaced(every interval: Duration) async {
    while !Task.isCancelled {
      do { try await Task.sleep(for: interval) } catch { return }
      let restart = Self.shouldRestartForReplacedExecutable(
        startup: startupExecutableStamp, current: Self.currentExecutableStamp(),
        hasRunningOperation: operations.contains { $0.state == "running" })
      if restart {
        persist()
        Darwin.exit(0)
      }
    }
  }
}
