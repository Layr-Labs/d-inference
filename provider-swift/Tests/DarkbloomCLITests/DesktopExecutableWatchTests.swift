import Foundation
import Testing

@testable import darkbloom

/// The desktop API exits (for launchd to relaunch the replacement) only when
/// its executable was really replaced and no operation is running.
struct DesktopExecutableWatchTests {
  static let unknown = DesktopBackend.unknownExecutableStamp

  @Test(arguments: [
    // startup, current, running operation, restart
    ("1:10:a", "2:10:b", false, true),
    ("1:10:a", "2:10:b", true, false),
    ("1:10:a", "1:10:a", false, false),
    (unknown, "2:10:b", false, false),
    ("1:10:a", unknown, false, false),
    (unknown, unknown, false, false),
  ])
  func restartsOnlyForAReadableReplacementWhileIdle(
    startup: String, current: String, running: Bool, restart: Bool
  ) {
    #expect(
      DesktopBackend.shouldRestartForReplacedExecutable(
        startup: startup, current: current, hasRunningOperation: running) == restart)
  }

  @Test func stampChangesWhenTheFileIsReplacedAndIsUnknownWhenMissing() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-stamp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("darkbloom")
    try Data("old".utf8).write(to: binary)
    let startup = DesktopBackend.executableStamp(at: binary.path)
    #expect(startup != Self.unknown)
    #expect(DesktopBackend.executableStamp(at: binary.path) == startup)

    // The updater installs by atomic rename/exchange, which changes the inode.
    let replacement = directory.appendingPathComponent(".darkbloom.new")
    try Data("new".utf8).write(to: replacement)
    #expect(rename(replacement.path, binary.path) == 0)
    #expect(DesktopBackend.executableStamp(at: binary.path) != startup)

    try FileManager.default.removeItem(at: binary)
    #expect(DesktopBackend.executableStamp(at: binary.path) == Self.unknown)
    #expect(DesktopBackend.executableStamp(at: nil) == Self.unknown)
  }
}
