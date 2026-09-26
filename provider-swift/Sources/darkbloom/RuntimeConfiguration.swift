import Foundation
import ProviderCore

struct RuntimeConfiguration {
    let configPath: URL
    let configFileExists: Bool
    let config: ProviderConfig
    let hardware: HardwareInfo?
    let hardwareError: Error?
}

/// Configuration edits must not depend on being able to discover models in the
/// old cache: `models location --reset` also repairs an invalid saved path.
func loadRuntimeConfiguration(
    configPath rawPath: String?,
    migrateOnDisk: Bool = true
) throws -> RuntimeConfiguration {
    let configPath: URL
    if let rawPath {
        configPath = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    } else {
        configPath = try ConfigManager.defaultConfigPath()
    }
    let configFileExists = FileManager.default.fileExists(atPath: configPath.path)
    let hardware: HardwareInfo?
    let hardwareError: Error?
    do {
        hardware = try HardwareDetector.detect()
        hardwareError = nil
    } catch {
        hardware = nil
        hardwareError = error
    }
    var config: ProviderConfig
    if configFileExists {
        config = try ConfigManager.load(from: configPath)
    } else if let hardware {
        config = ProviderConfig.defaultForHardware(hardware)
    } else {
        config = ConfigManager.loadDefault()
    }
    if migrateOnDisk {
        config = migrateConfigIfNeeded(
            configPath: configPath, config: config, copyToCanonical: rawPath == nil)
    }
    return RuntimeConfiguration(
        configPath: configPath, configFileExists: configFileExists,
        config: config, hardware: hardware, hardwareError: hardwareError)
}

/// Hash/removal need configuration, not a scan of every cached model.
func loadModelCacheConfiguration(configOptions: ConfigOptions) throws {
    Darkbloom.ensureLogging()
    let loaded = try loadRuntimeConfiguration(configPath: configOptions.config)
    ModelScanner.configureCacheDirectory(try ConfigManager.modelCacheDirectory(
        in: loaded.config, relativeTo: loaded.configPath))
}
