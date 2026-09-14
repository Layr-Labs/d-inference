import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineOwnership {
    struct Record: Codable {
        let schemaVersion: UInt16
        let installationID: UUID
        let name: String
        let cpuCount: UInt16
        let memoryBytes: UInt64
        let diskBytes: UInt64
        let sourceKind: String
        let sourceReference: String
        let sourceInstallationID: UUID?
        let unattendedPreset: String?
        let ownerKind: String
        let sandboxID: SandboxID?
        let sandboxGeneration: SandboxGeneration?

        init(
            specification: SandboxVirtualMachineSpecification,
            owner: Owner,
            sourceInstallationID: UUID?,
            installationID: UUID
        ) {
            schemaVersion = LumeVirtualMachineOwnership.schemaVersion
            self.installationID = installationID
            name = specification.name
            cpuCount = specification.resources.cpuCount
            memoryBytes = specification.resources.memoryBytes
            diskBytes = specification.diskBytes
            switch specification.imageSource {
            case .appleRestore(let url):
                sourceKind = "apple_restore"
                sourceReference = url.standardizedFileURL.path
                self.sourceInstallationID = nil
                unattendedPreset = nil
            case .restoreImage(let url, let preset):
                sourceKind = "restore_image"
                sourceReference = url.standardizedFileURL.path
                self.sourceInstallationID = nil
                unattendedPreset = preset
            case .localTemplate(let template):
                sourceKind = "local_template"
                sourceReference = template
                self.sourceInstallationID = sourceInstallationID
                unattendedPreset = nil
            }
            switch owner {
            case .baseTemplate:
                ownerKind = "base_template"
                sandboxID = nil
                sandboxGeneration = nil
            case .sandbox(let id, let generation):
                ownerKind = "sandbox"
                sandboxID = id
                sandboxGeneration = generation
            }
        }

        func matches(
            _ specification: SandboxVirtualMachineSpecification,
            owner: Owner
        ) -> Bool {
            let expected = Record(
                specification: specification,
                owner: owner,
                sourceInstallationID: sourceInstallationID,
                installationID: installationID
            )
            return schemaVersion == expected.schemaVersion
                && name == expected.name
                && cpuCount == expected.cpuCount
                && memoryBytes == expected.memoryBytes
                && diskBytes == expected.diskBytes
                && sourceKind == expected.sourceKind
                && sourceReference == expected.sourceReference
                && sourceInstallationID == expected.sourceInstallationID
                && unattendedPreset == expected.unattendedPreset
                && ownerKind == expected.ownerKind
                && sandboxID == expected.sandboxID
                && sandboxGeneration == expected.sandboxGeneration
        }

        func matches(owner: Owner) -> Bool {
            switch owner {
            case .baseTemplate:
                ownerKind == "base_template"
                    && sandboxID == nil
                    && sandboxGeneration == nil
            case .sandbox(let id, let generation):
                ownerKind == "sandbox"
                    && sandboxID == id
                    && sandboxGeneration == generation
            }
        }

        var isValid: Bool {
            guard schemaVersion == LumeVirtualMachineOwnership.schemaVersion,
                  SandboxVirtualMachineNamePolicy.isValid(name),
                  cpuCount > 0,
                  memoryBytes > 0,
                  diskBytes > 0,
                  !sourceReference.isEmpty,
                  matchesStoredOwner
            else {
                return false
            }
            switch sourceKind {
            case "apple_restore":
                return ownerKind == "base_template"
                    && sourceReference.hasPrefix("/")
                    && sourceInstallationID == nil
                    && unattendedPreset == nil
            case "restore_image":
                return sourceInstallationID == nil
                    && unattendedPreset == "tahoe"
            case "local_template":
                return SandboxVirtualMachineNamePolicy.isValid(sourceReference)
                    && sourceInstallationID != nil
                    && unattendedPreset == nil
            default:
                return false
            }
        }

        private var matchesStoredOwner: Bool {
            switch ownerKind {
            case "base_template":
                return sandboxID == nil && sandboxGeneration == nil
            case "sandbox":
                return sandboxID != nil && sandboxGeneration != nil
            default:
                return false
            }
        }
    }
}
