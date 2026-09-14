import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// The active root image scope encloses this entire operation. Native stopped
/// state was checked before taking source locks; those locks and exact opener
/// checks exclude any VM owner through staging and detach.
struct AccountlessOfflineStager {
    let journal: AccountlessInstallationStagingJournal
    let tools: AccountlessMountSystemTools
    let image: URL
    let imageDescriptor: Int32
    let validateOwnership: () throws -> Void

    func stage(payloadDirectory: URL) async throws {
        try validateOwnership()
        let attempts = try journal.mountAttempts()
        for attempt in try attempts.existing() {
            try requireSource(attempt)
            if try attempt.completion() == nil { try await cleanup(attempt) }
            else { try attempt.requireEmptyMountpoint(create: false) }
        }
        try Task.checkCancellation()
        let baseline = try await tools.inventory()
        guard try baseline.target(image, ownerUID: 0, writable: true) == nil else { throw AccountlessDiskError.unexpectedMount }
        try await tools.requireOnlyRetainedImageOpener(image: image, pid: getpid(), descriptor: imageDescriptor)
        let preserved = try baseline.images.map(AccountlessAttachmentSnapshot.init)
        let attempt = try attempts.create()
        try attempt.begin(.init(schemaVersion: 1, attemptName: attempt.directory.lastPathComponent,
            maintenanceSHA256: journal.maintenanceIntent().journalSHA256,
            imagePath: image.path, image: currentImage(), writable: true, baseline: preserved))
        do {
            try Task.checkCancellation()
            let reported = try await tools.attach(image, writable: true)
            let current = try await checkedInventory(attempt)
            let attached = try requireTarget(current)
            try attached.requireNoUnexpectedMounts()
            guard reported == attached.entities else { throw AccountlessDiskError.bindingChanged }
            let snapshot = try AccountlessAttachmentSnapshot(attached)
            try attempt.recordAttached(snapshot)
            let whole = try await tools.wholeDisk(of: attached, excluding: excluded(attempt))
            let binding = try await tools.disks.selectDataVolume(for: whole)
            try attempt.recordSelected(binding)
            try requireSameDevices(snapshot, in: await checkedInventory(attempt), allowedMount: nil)
            try Task.checkCancellation()
            try await tools.mount(binding, at: attempt.mountpoint, writable: true)
            try await tools.disks.requireMounted(binding, at: attempt.mountpoint, writable: true)
            try requireSameDevices(snapshot, in: await checkedInventory(attempt), allowedMount: attempt.mountpoint)
            try validateOwnership()
            try AccountlessMountedDataVolume.withVerifiedDirectory(at: attempt.mountpoint, binding: binding, writable: true) {
                try AccountlessOfflineOverlay().stage(dataDirectory: attempt.mountpoint,
                    payloadDirectory: payloadDirectory, journal: journal)
            }
            try validateOwnership()
        } catch {
            // A live system child still owns EX. Do not overlap cleanup with it
            // or signal it just to manufacture a completed attachment outcome.
            if case AccountlessDiskError.systemOperationPending = error { throw error }
            do { try await cleanup(attempt) }
            catch { throw AccountlessDiskError.cleanupUnproven }
            throw error
        }
        try await cleanup(attempt)
    }

    private func cleanup(_ attempt: AccountlessMountAttempt) async throws {
        try validateOwnership(); try requireSource(attempt)
        var current = try await checkedInventory(attempt)
        if let selected = try current.ownedTarget(image, ownerUID: 0) {
            guard try attempt.intent() != nil else { throw AccountlessDiskError.cleanupUnproven }
            try selected.requireNoUnexpectedMounts(allowed: attempt.mountpoint)
            if let original = try attempt.attached() {
                try requireSameDevices(original, in: current, allowedMount: attempt.mountpoint)
            }
            let whole = try await tools.wholeDisk(of: selected, excluding: excluded(attempt))
            // Reobserve the exact image and node identities immediately before
            // detach; a saved BSD number alone never authorizes this operation.
            let before = try AccountlessAttachmentSnapshot(selected)
            current = try await checkedInventory(attempt)
            try requireSameDevices(before, in: current, allowedMount: attempt.mountpoint)
            try await tools.detach(whole)
            current = try await checkedInventory(attempt)
        }
        guard try current.ownedTarget(image, ownerUID: 0) == nil else { throw AccountlessDiskError.cleanupUnproven }
        try attempt.requireEmptyMountpoint(create: false)
        try await tools.requireOnlyRetainedImageOpener(image: image, pid: getpid(), descriptor: imageDescriptor)
        try validateOwnership()
        try attempt.recordDetached(image: currentImage())
    }

    private func checkedInventory(_ attempt: AccountlessMountAttempt) async throws -> AccountlessAttachmentInventory {
        try validateOwnership()
        let inventory = try await tools.inventory()
        let baseline = try attempt.intent()?.baseline ?? []
        try AccountlessAttachmentSnapshot.requirePreserved(baseline, in: inventory, excluding: image)
        if let target = try inventory.ownedTarget(image, ownerUID: 0) {
            guard target.devices.isDisjoint(with: Set(baseline.flatMap { $0.attachment.devices })) else {
                throw AccountlessDiskError.bindingChanged
            }
        }
        try validateOwnership()
        return inventory
    }

    private func requireSameDevices(_ original: AccountlessAttachmentSnapshot, in inventory: AccountlessAttachmentInventory,
                                    allowedMount: URL?) throws {
        guard let target = try inventory.ownedTarget(image, ownerUID: 0) else { throw AccountlessDiskError.bindingChanged }
        try target.requireNoUnexpectedMounts(allowed: allowedMount)
        let current = try AccountlessAttachmentSnapshot(target)
        guard current.image == original.image, current.attachment.ownerUID == original.attachment.ownerUID,
              current.attachment.writable == original.attachment.writable,
              current.devices.map(\.identifier) == original.devices.map(\.identifier),
              current.devices.map(\.node) == original.devices.map(\.node) else { throw AccountlessDiskError.bindingChanged }
    }

    private func requireTarget(_ inventory: AccountlessAttachmentInventory) throws -> AccountlessAttachedImage {
        guard let target = try inventory.target(image, ownerUID: 0, writable: true) else { throw AccountlessDiskError.bindingChanged }
        return target
    }

    private func excluded(_ attempt: AccountlessMountAttempt) throws -> Set<AccountlessDiskIdentifier> {
        Set(try attempt.intent()?.baseline.flatMap { $0.attachment.devices } ?? [])
    }

    private func currentImage() throws -> LumeCandidateDiskIdentity {
        try validateOwnership()
        return try .init(SandboxAuthorityFileSystem.fileMetadata(imageDescriptor))
    }

    private func requireSource(_ attempt: AccountlessMountAttempt) throws {
        if let intent = try attempt.intent() {
            let current = try currentImage()
            guard intent.imagePath == image.path, intent.writable, intent.image.device == current.device,
                  intent.image.inode == current.inode, intent.image.size == current.size else { throw AccountlessDiskError.bindingChanged }
        }
        if let completed = try attempt.completion() {
            let current = try currentImage()
            guard completed.image.device == current.device, completed.image.inode == current.inode,
                  completed.image.size == current.size else { throw AccountlessDiskError.bindingChanged }
        }
    }
}
