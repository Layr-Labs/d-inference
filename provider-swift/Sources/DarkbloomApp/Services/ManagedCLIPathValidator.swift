import Darwin
import Foundation
import ProviderCoreFoundation

/// Validates the managed CLI without following a symbolic link in any path
/// component.
///
/// Each pass walks from `/` with `openat(O_NOFOLLOW)`, so an ancestor cannot
/// redirect lookup outside the canonical install tree. Comparing two complete
/// descriptor identity snapshots also rejects a component replaced while the
/// validation is in progress.
struct ManagedCLIPathValidator {
    func validatedCLIURL(homeDirectory: URL) -> URL? {
        validatedCLIURL(
            homeDirectory: homeDirectory,
            betweenValidationPasses: {}
        )
    }

    /// The hook makes replacement-race behavior deterministic in tests. The
    /// shipping locator always uses the hook-free overload above.
    func validatedCLIURL(
        homeDirectory: URL,
        betweenValidationPasses: () throws -> Void
    ) rethrows -> URL? {
        guard let components = traversalComponents(homeDirectory: homeDirectory),
              let firstSnapshot = descriptorSnapshot(components: components)
        else {
            return nil
        }

        try betweenValidationPasses()

        guard let secondSnapshot = descriptorSnapshot(components: components),
              firstSnapshot == secondSnapshot
        else {
            return nil
        }

        return ManagedProviderInstallLayout.cliURL(
            homeDirectory: homeDirectory
        )
    }

    private func traversalComponents(homeDirectory: URL) -> [String]? {
        guard homeDirectory.isFileURL else { return nil }

        let standardizedHome = homeDirectory.standardizedFileURL
        guard standardizedHome.path == homeDirectory.path else {
            return nil
        }

        let absoluteComponents = standardizedHome.pathComponents
        guard absoluteComponents.first == "/" else { return nil }

        return Array(absoluteComponents.dropFirst())
            + ManagedProviderInstallLayout.cliPathComponents
    }

    private func descriptorSnapshot(
        components: [String]
    ) -> [ResourceIdentity]? {
        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        guard let rootIdentity = resourceIdentity(
            descriptor: descriptor,
            expectedKind: mode_t(S_IFDIR)
        ) else {
            return nil
        }

        var snapshot = [rootIdentity]
        for (index, component) in components.enumerated() {
            let isExecutable = index == components.count - 1
            var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            if !isExecutable {
                flags |= O_DIRECTORY
            }

            let childDescriptor = component.withCString {
                openat(descriptor, $0, flags)
            }
            guard childDescriptor >= 0 else { return nil }

            let expectedKind = mode_t(isExecutable ? S_IFREG : S_IFDIR)
            guard let identity = resourceIdentity(
                descriptor: childDescriptor,
                expectedKind: expectedKind,
                requiresExecuteBit: isExecutable
            ) else {
                close(childDescriptor)
                return nil
            }

            close(descriptor)
            descriptor = childDescriptor
            snapshot.append(identity)
        }
        return snapshot
    }

    private func resourceIdentity(
        descriptor: Int32,
        expectedKind: mode_t,
        requiresExecuteBit: Bool = false
    ) -> ResourceIdentity? {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == expectedKind
        else {
            return nil
        }

        if requiresExecuteBit {
            let executableBits =
                mode_t(S_IXUSR) | mode_t(S_IXGRP) | mode_t(S_IXOTH)
            guard attributes.st_mode & executableBits != 0 else {
                return nil
            }
        }

        return ResourceIdentity(
            device: UInt64(bitPattern: Int64(attributes.st_dev)),
            inode: UInt64(attributes.st_ino),
            generation: UInt64(attributes.st_gen)
        )
    }
}

private struct ResourceIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt64
}
