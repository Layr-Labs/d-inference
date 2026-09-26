import Foundation
import ProviderCore

func hfCacheCheck(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    configuredDirectory: String? = nil
) -> DoctorCheck {
    let resolved = ModelScanner.resolveCache(
        homeDirectory: homeDirectory,
        configuredDirectory: configuredDirectory)
    let cacheDir = resolved.url
    let source = resolved.isConfigured ? " (via backend.model_cache_directory)" : ""
    let fm = FileManager.default
    guard ModelScanner.isUsableCacheDirectory(cacheDir) else {
        let reason = fm.fileExists(atPath: cacheDir.path) ? "not a directory" : "not found"
        return .init(name: "huggingface cache", status: .warn,
                     detail: "\(reason): \(cacheDir.path)\(source)")
    }
    guard fm.isReadableFile(atPath: cacheDir.path), fm.isExecutableFile(atPath: cacheDir.path) else {
        return .init(name: "huggingface cache", status: .warn,
                     detail: "not readable/searchable: \(cacheDir.path)\(source)")
    }
    let homeDefault = ModelScanner.homeCacheDirectory(homeDirectory: homeDirectory)
    if cacheDir.path != homeDefault.path,
       ModelScanner.scanAllModels(in: cacheDir, environment: [:]).isEmpty,
       !ModelScanner.scanAllModels(in: homeDefault, environment: [:]).isEmpty {
        return .init(
            name: "huggingface cache", status: .warn,
            detail: "no local MLX models: \(cacheDir.path)\(source); models are in \(homeDefault.path)")
    }
    return .init(name: "huggingface cache", status: .pass, detail: cacheDir.path + source)
}
