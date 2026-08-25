import Foundation

/// Path snapshots used by recovery before it reads or mutates a journal-owned
/// layout. All inspection is `lstat(2)` based: a symlink is classified as a
/// symlink rather than silently followed to an external directory.
extension UpdateRecoveryStore {
    struct RecoveryNodeSnapshot: Sendable {
        let url: URL
        let identity: UpdateAtomicFilesystem.ItemIdentity?
        let symbolicLinkTarget: String?
        let label: String

        func assertUnchanged() throws {
            let current = try UpdateAtomicFilesystem.itemIdentity(at: url)
            guard current == identity else {
                throw StoreError.corruptTransaction(
                    "\(label) was replaced after validation")
            }
            if identity?.kind == .symbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                )
                guard target == symbolicLinkTarget else {
                    throw StoreError.corruptTransaction(
                        "\(label) symbolic-link target changed after validation")
                }
            }
        }
    }

    struct RecoveryLayoutSnapshot: Sendable {
        let root: RecoveryNodeSnapshot
        let component: RecoveryNodeSnapshot
        let binary: URL
        let enclave: URL
        let metallib: URL
        let nodes: [RecoveryNodeSnapshot]
        let payloadsAreRegularFiles: Bool

        func assertUnchanged() throws {
            for node in nodes {
                try node.assertUnchanged()
            }
        }
    }

    struct RecoveryMutationGuard: Sendable {
        let installRoot: RecoveryNodeSnapshot
        let destination: RecoveryNodeSnapshot
        let canonicalBin: RecoveryNodeSnapshot?
        let staleApp: RecoveryNodeSnapshot?

        func assertUnchanged() throws {
            try installRoot.assertUnchanged()
            try destination.assertUnchanged()
            try canonicalBin?.assertUnchanged()
            try staleApp?.assertUnchanged()
        }
    }

    func recoveryNodeSnapshot(
        at url: URL,
        label: String
    ) throws -> RecoveryNodeSnapshot {
        let identity = try UpdateAtomicFilesystem.itemIdentity(at: url)
        let target: String?
        if identity?.kind == .symbolicLink {
            target = try fm.destinationOfSymbolicLink(atPath: url.path)
        } else {
            target = nil
        }
        return RecoveryNodeSnapshot(
            url: url.standardizedFileURL,
            identity: identity,
            symbolicLinkTarget: target,
            label: label
        )
    }

    func validatedJournalStagingRoot(
        path: String,
        expectedPrefix: String
    ) throws -> RecoveryNodeSnapshot {
        let stagingRoot = URL(fileURLWithPath: path).standardizedFileURL
        guard stagingRoot.deletingLastPathComponent() == installRoot,
              stagingRoot.lastPathComponent.hasPrefix(expectedPrefix),
              stagingRoot.lastPathComponent.count > expectedPrefix.count
        else {
            throw StoreError.corruptTransaction(
                "staging path is not a direct child in the allowed install-root namespace")
        }

        let resolvedRoot = installRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedStaging = stagingRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedStaging.deletingLastPathComponent() == resolvedRoot else {
            throw StoreError.corruptTransaction(
                "staging path resolves outside the install root")
        }

        let snapshot = try recoveryNodeSnapshot(
            at: stagingRoot,
            label: "journal staging root"
        )
        if let identity = snapshot.identity, identity.kind != .directory {
            throw unsafeNode(
                snapshot,
                expected: "a directory (symbolic links are forbidden)"
            )
        }
        return snapshot
    }

    /// Validate the component and every fixed payload path that matching,
    /// signature verification, or promotion will touch. Missing nodes mean the
    /// layout is incomplete and therefore cannot match. Existing nodes of the
    /// wrong kind are corruption, not a recoverable hash miss.
    func validatedRecoveryLayout(
        root: URL,
        layout: VerifiedPredecessor.Layout,
        context: String,
        allowCanonicalAppLinksForFlatLive: Bool = false
    ) throws -> RecoveryLayoutSnapshot? {
        let standardizedRoot = root.standardizedFileURL
        let rootNode = try recoveryNodeSnapshot(
            at: standardizedRoot,
            label: "\(context) root"
        )
        guard let rootIdentity = rootNode.identity else { return nil }
        guard rootIdentity.kind == .directory else {
            throw unsafeNode(
                rootNode,
                expected: "a directory (symbolic links are forbidden)"
            )
        }

        var nodes = [rootNode]
        let component: URL
        let binary: URL
        let enclave: URL
        let metallib: URL
        var payloadsAreRegular = true

        switch layout {
        case .app:
            component = standardizedRoot.appendingPathComponent("Darkbloom.app")
            try requireDirectChild(component, of: standardizedRoot, label: "app bundle")
            guard let appNode = try requiredNode(
                at: component,
                kind: .directory,
                label: "\(context) app bundle",
                nodes: &nodes
            ) else { return nil }

            let contents = component.appendingPathComponent("Contents")
            try requireDirectChild(contents, of: component, label: "app Contents")
            guard try requiredNode(
                at: contents,
                kind: .directory,
                label: "\(context) app Contents",
                nodes: &nodes
            ) != nil else { return nil }

            let macOS = contents.appendingPathComponent("MacOS")
            try requireDirectChild(macOS, of: contents, label: "app MacOS")
            guard try requiredNode(
                at: macOS,
                kind: .directory,
                label: "\(context) app MacOS",
                nodes: &nodes
            ) != nil else { return nil }

            binary = macOS.appendingPathComponent("darkbloom")
            enclave = macOS.appendingPathComponent("darkbloom-enclave")
            metallib = macOS.appendingPathComponent("mlx.metallib")
            for (url, label) in [
                (binary, "darkbloom"),
                (enclave, "darkbloom-enclave"),
                (metallib, "mlx.metallib"),
            ] {
                try requireDirectChild(url, of: macOS, label: label)
                guard try requiredNode(
                    at: url,
                    kind: .regularFile,
                    label: "\(context) app payload \(label)",
                    nodes: &nodes
                ) != nil else { return nil }
            }
            _ = appNode

        case .flat:
            component = standardizedRoot.appendingPathComponent("bin")
            try requireDirectChild(component, of: standardizedRoot, label: "flat bin")
            guard try requiredNode(
                at: component,
                kind: .directory,
                label: "\(context) flat bin",
                nodes: &nodes
            ) != nil else { return nil }

            binary = component.appendingPathComponent("darkbloom")
            enclave = component.appendingPathComponent("darkbloom-enclave")
            metallib = component.appendingPathComponent("mlx.metallib")
            let canonicalTargets = [
                "darkbloom": "../Darkbloom.app/Contents/MacOS/darkbloom",
                "darkbloom-enclave":
                    "../Darkbloom.app/Contents/MacOS/darkbloom-enclave",
                "mlx.metallib": "../Darkbloom.app/Contents/MacOS/mlx.metallib",
            ]
            for (url, label) in [
                (binary, "darkbloom"),
                (enclave, "darkbloom-enclave"),
                (metallib, "mlx.metallib"),
            ] {
                try requireDirectChild(url, of: component, label: label)
                let node = try recoveryNodeSnapshot(
                    at: url,
                    label: "\(context) flat payload \(label)"
                )
                guard let identity = node.identity else { return nil }
                if identity.kind == .regularFile {
                    nodes.append(node)
                    continue
                }
                if allowCanonicalAppLinksForFlatLive,
                   identity.kind == .symbolicLink,
                   node.symbolicLinkTarget == canonicalTargets[label]
                {
                    payloadsAreRegular = false
                    nodes.append(node)
                    continue
                }
                throw unsafeNode(
                    node,
                    expected: "a regular file (symbolic links are forbidden)"
                )
            }

            let legacy = component.appendingPathComponent(
                "eigeninference-enclave")
            try requireDirectChild(
                legacy,
                of: component,
                label: "legacy enclave link"
            )
            let legacyNode = try recoveryNodeSnapshot(
                at: legacy,
                label: "\(context) legacy enclave link"
            )
            guard let legacyIdentity = legacyNode.identity else { return nil }
            guard legacyIdentity.kind == .symbolicLink,
                  legacyNode.symbolicLinkTarget == "darkbloom-enclave"
            else {
                throw unsafeNode(
                    legacyNode,
                    expected: "the canonical darkbloom-enclave symbolic link"
                )
            }
            nodes.append(legacyNode)
        }

        guard let componentNode = nodes.first(where: { $0.url == component }) else {
            throw StoreError.corruptTransaction(
                "\(context) component validation did not produce an identity")
        }
        return RecoveryLayoutSnapshot(
            root: rootNode,
            component: componentNode,
            binary: binary,
            enclave: enclave,
            metallib: metallib,
            nodes: nodes,
            payloadsAreRegularFiles: payloadsAreRegular
        )
    }

    /// Capture every live path that installation or canonical-link repair can
    /// exchange, rename, create beneath, or remove. This is deliberately done
    /// before the source component is promoted.
    func recoveryMutationGuard(
        layout: VerifiedPredecessor.Layout
    ) throws -> RecoveryMutationGuard {
        let root = try recoveryNodeSnapshot(
            at: installRoot,
            label: "install root"
        )
        guard root.identity?.kind == .directory else {
            throw unsafeNode(
                root,
                expected: "a directory (symbolic links are forbidden)"
            )
        }

        let destination: URL
        let canonicalBin: RecoveryNodeSnapshot?
        let staleApp: RecoveryNodeSnapshot?
        switch layout {
        case .app:
            destination = installRoot.appendingPathComponent("Darkbloom.app")
            try requireDirectChild(
                destination,
                of: installRoot,
                label: "live app destination"
            )
            let bin = installRoot.appendingPathComponent("bin")
            try requireDirectChild(bin, of: installRoot, label: "canonical bin")
            canonicalBin = try optionalDirectory(
                at: bin,
                label: "canonical bin directory"
            )
            staleApp = nil

        case .flat:
            destination = installRoot.appendingPathComponent("bin")
            try requireDirectChild(
                destination,
                of: installRoot,
                label: "live flat destination"
            )
            canonicalBin = nil
            let app = installRoot.appendingPathComponent("Darkbloom.app")
            try requireDirectChild(app, of: installRoot, label: "stale app")
            staleApp = try optionalDirectory(
                at: app,
                label: "stale app bundle"
            )
        }

        let destinationNode = try optionalDirectory(
            at: destination,
            label: "live \(layout.rawValue) destination"
        )
        return RecoveryMutationGuard(
            installRoot: root,
            destination: destinationNode,
            canonicalBin: canonicalBin,
            staleApp: staleApp
        )
    }

    private func requiredNode(
        at url: URL,
        kind: UpdateAtomicFilesystem.ItemKind,
        label: String,
        nodes: inout [RecoveryNodeSnapshot]
    ) throws -> RecoveryNodeSnapshot? {
        let node = try recoveryNodeSnapshot(at: url, label: label)
        guard let identity = node.identity else { return nil }
        guard identity.kind == kind else {
            let expected = kind == .directory
                ? "a directory (symbolic links are forbidden)"
                : "a regular file (symbolic links are forbidden)"
            throw unsafeNode(node, expected: expected)
        }
        nodes.append(node)
        return node
    }

    private func optionalDirectory(
        at url: URL,
        label: String
    ) throws -> RecoveryNodeSnapshot {
        let node = try recoveryNodeSnapshot(at: url, label: label)
        if let identity = node.identity, identity.kind != .directory {
            throw unsafeNode(
                node,
                expected: "a directory (symbolic links are forbidden)"
            )
        }
        return node
    }

    private func requireDirectChild(
        _ child: URL,
        of parent: URL,
        label: String
    ) throws {
        guard child.standardizedFileURL.deletingLastPathComponent()
                == parent.standardizedFileURL
        else {
            throw StoreError.corruptTransaction(
                "\(label) is not a direct descendant of its validated parent")
        }
    }

    private func unsafeNode(
        _ node: RecoveryNodeSnapshot,
        expected: String
    ) -> StoreError {
        let actual: String
        switch node.identity?.kind {
        case .directory:
            actual = "directory"
        case .regularFile:
            actual = "regular file"
        case .symbolicLink:
            actual = "symbolic link"
        case .other:
            actual = "unsupported node"
        case nil:
            actual = "missing node"
        }
        return .corruptTransaction(
            "\(node.label) must be \(expected), found \(actual)")
    }
}
