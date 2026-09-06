import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Selects a real executable inside the managed app without following symlinks.
/// Both passes include every ancestor and the helper-presence decision. Legacy
/// fallback is allowed only when Helpers or DarkbloomProvider.app is absent;
/// once the helper exists, a malformed nested path fails closed.
/// Bundle signatures and signing metadata are verified by the install flow.
public struct ManagedProviderCLIPathValidator {
    public init() {}

    public func validatedCLIURL(homeDirectory: URL) -> URL? {
        validatedCLIURL(homeDirectory: homeDirectory, betweenValidationPasses: {})
    }

    /// A deterministic replacement-race seam. Production callers use the
    /// hook-free overload so both identity snapshots happen consecutively.
    public func validatedCLIURL(
        homeDirectory: URL,
        betweenValidationPasses: () throws -> Void
    ) rethrows -> URL? {
        guard let homeComponents = absoluteComponents(of: homeDirectory) else { return nil }
        return try validatedCLIURL(
            appBundleURL: ManagedProviderInstallLayout.appURL(homeDirectory: homeDirectory),
            bundleComponents: homeComponents + ManagedProviderInstallLayout.appPathComponents,
            betweenValidationPasses: betweenValidationPasses
        )
    }

    public func validatedCLIURL(appBundleURL: URL) -> URL? {
        guard let components = absoluteComponents(of: appBundleURL) else { return nil }
        return validatedCLIURL(
            appBundleURL: appBundleURL,
            bundleComponents: components,
            betweenValidationPasses: {}
        )
    }

    private func validatedCLIURL(
        appBundleURL: URL,
        bundleComponents: [String],
        betweenValidationPasses: () throws -> Void
    ) rethrows -> URL? {
        guard let first = descriptorSnapshot(bundleComponents: bundleComponents) else { return nil }
        try betweenValidationPasses()
        guard let second = descriptorSnapshot(bundleComponents: bundleComponents),
              first == second
        else { return nil }

        switch first.layout {
        case .nested:
            return ManagedProviderInstallLayout.cliURL(appBundleURL: appBundleURL)
        case .legacy:
            return ManagedProviderInstallLayout.legacyCLIURL(appBundleURL: appBundleURL)
        }
    }

    private func absoluteComponents(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        let path = url.path
        let lexicalComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !lexicalComponents.contains("."),
              !lexicalComponents.contains(".."),
              url.pathComponents.first == "/"
        else { return nil }

        // Do not standardize: Foundation can rewrite /private/var through the
        // /var symlink on macOS, defeating the no-symlink descriptor walk.
        return Array(url.pathComponents.dropFirst())
    }

    private var directoryFlags: Int32 {
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    }

    private func descriptorSnapshot(bundleComponents: [String]) -> Snapshot? {
        var descriptor = open("/", directoryFlags)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let root = resourceIdentity(descriptor: descriptor, isExecutable: false) else { return nil }
        var identities = [root]
        guard walk(
            bundleComponents + ["Contents"],
            descriptor: &descriptor,
            identities: &identities
        ) else { return nil }

        let helperComponents = ManagedProviderInstallLayout.helperAppPathComponents
        var helperDescriptor = helperComponents[1].withCString {
            openat(descriptor, $0, directoryFlags)
        }
        if helperDescriptor < 0 {
            guard errno == ENOENT else { return nil }
            return legacySnapshot(descriptor: &descriptor, identities: &identities)
        }
        defer { close(helperDescriptor) }
        guard let helpers = resourceIdentity(descriptor: helperDescriptor, isExecutable: false) else { return nil }
        identities.append(helpers)

        let bundleDescriptor = helperComponents[2].withCString {
            openat(helperDescriptor, $0, directoryFlags)
        }
        if bundleDescriptor < 0 {
            guard errno == ENOENT else { return nil }
            return legacySnapshot(descriptor: &descriptor, identities: &identities)
        }
        close(helperDescriptor)
        helperDescriptor = bundleDescriptor
        guard let helper = resourceIdentity(descriptor: helperDescriptor, isExecutable: false) else { return nil }
        identities.append(helper)
        guard walk(
            ManagedProviderInstallLayout.helperExecutablePathComponents,
            descriptor: &helperDescriptor,
            identities: &identities,
            finalIsExecutable: true
        ) else { return nil }
        return Snapshot(layout: .nested, identities: identities)
    }

    private func legacySnapshot(
        descriptor: inout Int32,
        identities: inout [ResourceIdentity]
    ) -> Snapshot? {
        guard walk(
            Array(ManagedProviderInstallLayout.helperExecutablePathComponents.dropFirst()),
            descriptor: &descriptor,
            identities: &identities,
            finalIsExecutable: true
        ) else { return nil }
        return Snapshot(layout: .legacy, identities: identities)
    }

    private func walk(
        _ components: [String],
        descriptor: inout Int32,
        identities: inout [ResourceIdentity],
        finalIsExecutable: Bool = false
    ) -> Bool {
        for (index, component) in components.enumerated() {
            let isExecutable = finalIsExecutable && index == components.count - 1
            // NONBLOCK prevents a malicious FIFO leaf from blocking before
            // fstat can reject it. It has no effect on regular files.
            let flags = isExecutable
                ? O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                : directoryFlags
            let child = component.withCString { openat(descriptor, $0, flags) }
            guard child >= 0 else { return false }
            guard let identity = resourceIdentity(descriptor: child, isExecutable: isExecutable) else {
                close(child)
                return false
            }
            close(descriptor)
            descriptor = child
            identities.append(identity)
        }
        return true
    }

    private func resourceIdentity(descriptor: Int32, isExecutable: Bool) -> ResourceIdentity? {
        var attributes = stat()
        let expectedKind = mode_t(isExecutable ? S_IFREG : S_IFDIR)
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == expectedKind
        else { return nil }
        if isExecutable {
            let executableBits = mode_t(S_IXUSR) | mode_t(S_IXGRP) | mode_t(S_IXOTH)
            guard attributes.st_mode & executableBits != 0 else { return nil }
        }
        #if canImport(Darwin)
        let generation = UInt64(attributes.st_gen)
        #else
        let generation: UInt64 = 0
        #endif
        return ResourceIdentity(
            device: UInt64(bitPattern: Int64(attributes.st_dev)),
            inode: UInt64(attributes.st_ino),
            generation: generation
        )
    }
}

private struct Snapshot: Equatable {
    enum Layout: Equatable { case nested, legacy }
    let layout: Layout
    let identities: [ResourceIdentity]
}

private struct ResourceIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt64
}
