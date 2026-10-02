import Foundation
import ProviderCore

extension DesktopBackend {
  /// Hardware discovery may run system_profiler. It is immutable for this API
  /// process; only the small configuration file needs rereading during polling.
  func configuration() throws -> RuntimeConfiguration {
    guard let previous = cachedConfiguration else {
      let loaded = try loadRuntimeConfiguration(configPath: configPath)
      cachedConfiguration = loaded
      cachedConfigurationRevision = DesktopStorage.revision(loaded.configPath)
      return loaded
    }
    let revision = DesktopStorage.revision(previous.configPath)
    guard revision != cachedConfigurationRevision else { return previous }
    let exists = FileManager.default.fileExists(atPath: previous.configPath.path)
    let config =
      exists ? try ConfigManager.load(from: previous.configPath) : ConfigManager.loadDefault()
    let loaded = RuntimeConfiguration(
      configPath: previous.configPath, configFileExists: exists,
      config: config, hardware: previous.hardware, hardwareError: previous.hardwareError)
    if config.coordinator.url != previous.config.coordinator.url {
      catalog = []
      catalogAt = .distantPast
    }
    localAt = .distantPast
    cachedConfiguration = loaded
    cachedConfigurationRevision = revision
    return loaded
  }
}
