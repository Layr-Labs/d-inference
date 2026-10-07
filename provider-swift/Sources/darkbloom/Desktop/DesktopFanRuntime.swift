import Foundation

/// Fan XPC authenticates signed providers. The desktop preview must use the
/// installed signed runtime for status and root-helper operations.
enum DesktopFanRuntime {
  static func resolve() throws -> URL {
    let manager = FanServiceManager()
    let current = try manager.currentExecutableURL()
    let installed = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".darkbloom/Darkbloom.app/Contents/MacOS/darkbloom")
    return try select([current, installed]) { executable in
      let directory = executable.deletingLastPathComponent()
      guard directory.lastPathComponent == "MacOS" else { return false }
      let contents = directory.deletingLastPathComponent()
      let app = contents.deletingLastPathComponent()
      guard app.pathExtension == "app" else { return false }
      try manager.verifyRegularExecutable(executable)
      try manager.verifyBundledApp(app: app, executable: executable,
        helper: contents.appendingPathComponent("Helpers/darkbloom-fan-helper"))
      return true
    }
  }

  static func select(_ candidates: [URL], verify: (URL) throws -> Bool) throws -> URL {
    for candidate in candidates {
      if (try? verify(candidate)) == true { return candidate }
    }
    throw FanServiceManagerError.helperNotBundled(["a verified signed Darkbloom.app installation"])
  }
}
