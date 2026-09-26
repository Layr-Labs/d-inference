import ArgumentParser
import Foundation
import ProviderCore

struct ModelCacheLocationInspection {
    let directory: URL
    let modelIDs: [String]
    let problem: String?
}

/// Inspect only this cache root, never an environment-selected staged model.
/// Discovery does not establish weight integrity or network eligibility.
func inspectModelCacheLocation(_ directory: URL) -> ModelCacheLocationInspection {
    let problem = modelCacheLocationProblem(directory)
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    let readable = fm.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        && isDirectory.boolValue && fm.isReadableFile(atPath: directory.path)
        && fm.isExecutableFile(atPath: directory.path)
    let ids = readable
        ? ModelScanner.scanAllModels(in: directory, environment: [:]).map(\.id).sorted()
        : []
    return ModelCacheLocationInspection(directory: directory, modelIDs: ids, problem: problem)
}

private func modelCacheLocationProblem(_ directory: URL) -> String? {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
        return "Directory does not exist: \(directory.path). Check that any external volume is mounted, then create the directory explicitly with mkdir before selecting it."
    }
    guard isDirectory.boolValue else {
        return "Not a directory: \(directory.path)"
    }
    guard fm.isReadableFile(atPath: directory.path), fm.isExecutableFile(atPath: directory.path) else {
        return "Directory is not readable/searchable: \(directory.path)"
    }
    guard fm.isWritableFile(atPath: directory.path) else {
        return "Directory is not writable for future downloads: \(directory.path)"
    }
    return nil
}

/// Keep config mutation behind confirmation and reload under the shared lock.
/// A nil directory removes the saved setting, not any model files.
@discardableResult
func setModelCacheLocation(
    _ directory: URL?,
    configPath: String?,
    migrateOnDisk: Bool = true
) throws -> (path: URL, changed: Bool) {
    if let directory, let problem = modelCacheLocationProblem(directory) {
        throw ValidationError(problem)
    }
    return try withMutableConfig(configPath: configPath, migrateOnDisk: migrateOnDisk) { savePath, config in
        guard config.backend.modelCacheDirectory != directory?.path else {
            return (savePath, false)
        }
        config.backend.modelCacheDirectory = directory?.path
        try ConfigManager.save(config, to: savePath)
        return (savePath, true)
    }
}
