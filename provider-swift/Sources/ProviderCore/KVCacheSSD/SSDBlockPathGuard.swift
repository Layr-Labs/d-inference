// Copyright © 2026 Eigen Labs.

import Foundation

extension SSDBlockStore {
    /// Create and validate the production `<dedicatedRoot>/<modelKey>` pair
    /// without accepting a symlinked existing component. The model root must
    /// be a direct child of the dedicated cache hierarchy.
    static func prepareModelRoot(dedicatedRoot: URL, modelRoot: URL) throws {
        let dedicated = dedicatedRoot.standardizedFileURL
        let model = modelRoot.standardizedFileURL
        guard model.deletingLastPathComponent().path == dedicated.path,
            pathResolvesToItself(dedicated), pathResolvesToItself(model)
        else { throw SSDBlockStoreError.ioFailure("unsafe cache root") }

        let fm = FileManager.default
        if !fm.fileExists(atPath: dedicated.path) {
            try fm.createDirectory(at: dedicated, withIntermediateDirectories: true)
        }
        guard isRealDirectory(dedicated), pathResolvesToItself(dedicated) else {
            throw SSDBlockStoreError.ioFailure("dedicated cache root is symlinked")
        }
        if !fm.fileExists(atPath: model.path) {
            try fm.createDirectory(at: model, withIntermediateDirectories: false)
        }
        guard isSafeModelRoot(model, dedicatedRoot: dedicated) else {
            throw SSDBlockStoreError.ioFailure("model cache root is symlinked or escaped")
        }
    }

    static func isSafeModelRoot(_ modelRoot: URL, dedicatedRoot: URL) -> Bool {
        let model = modelRoot.standardizedFileURL
        let dedicated = dedicatedRoot.standardizedFileURL
        return model.deletingLastPathComponent().path == dedicated.path
            && pathResolvesToItself(dedicated)
            && pathResolvesToItself(model)
            && isRealDirectory(dedicated)
            && isRealDirectory(model)
    }

    static func isSafeBlockURL(_ url: URL, modelRoot: URL? = nil) -> Bool {
        let file = url.standardizedFileURL
        let root = (modelRoot ?? file.deletingLastPathComponent().deletingLastPathComponent())
            .standardizedFileURL
        let fanout = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        guard file.pathExtension == fileExtension,
            isLowerHex(stem, count: 32),
            isLowerHex(fanout.lastPathComponent, count: 2),
            stem.hasPrefix(fanout.lastPathComponent),
            fanout.deletingLastPathComponent().path == root.path,
            isSafeModelRoot(root, dedicatedRoot: root.deletingLastPathComponent()),
            pathResolvesToItself(fanout), pathResolvesToItself(file)
        else { return false }
        if FileManager.default.fileExists(atPath: fanout.path), !isRealDirectory(fanout) {
            return false
        }
        return true
    }

    @discardableResult
    static func removeItemIfSafe(
        at url: URL,
        under root: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) -> Bool {
        guard isSafeDescendant(url, under: root), isRealRegularFile(url) else { return false }
        return SSDNoFollowIO.unlinkRegularFile(
            at: url, beforeOperation: beforeOperation)
    }

    static func setAttributesIfSafe(
        _ attributes: [FileAttributeKey: Any],
        at url: URL,
        under root: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) {
        guard isSafeDescendant(url, under: root), isRealRegularFile(url),
            let modificationDate = attributes[.modificationDate] as? Date
        else { return }
        SSDNoFollowIO.touchRegularFile(
            at: url,
            modificationDate: modificationDate,
            beforeOperation: beforeOperation)
    }

    static func isSafeDescendant(_ url: URL, under root: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let canonicalRoot = root.standardizedFileURL
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        return candidate.path.hasPrefix(prefix)
            && pathResolvesToItself(canonicalRoot)
            && pathResolvesToItself(candidate)
    }

    static func pathResolvesToItself(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.path
            == standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func isRealRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
            && pathResolvesToItself(url)
    }
}
