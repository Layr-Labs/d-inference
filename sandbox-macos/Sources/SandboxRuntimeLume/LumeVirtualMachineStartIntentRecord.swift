import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineStartIntent {
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: UInt16
        let intentID: UUID
        let installationID: UUID
        let name: String
        let ownerKind: String
        let sandboxID: SandboxID?
        let sandboxGeneration: SandboxGeneration?
        let initiatingFencingToken: SandboxFencingToken?

        init(
            name: String,
            ownership: LumeVirtualMachineOwnership.Identity,
            owner: LumeVirtualMachineOwnership.Owner,
            initiatingScope: SandboxOperationScope?
        ) throws {
            schemaVersion = LumeVirtualMachineStartIntent.schemaVersion
            intentID = UUID()
            installationID = ownership.installationID
            self.name = name
            switch owner {
            case .baseTemplate:
                guard initiatingScope == nil else {
                    throw Self.mismatchFailure(name)
                }
                ownerKind = "base_template"
                sandboxID = nil
                sandboxGeneration = nil
                initiatingFencingToken = nil
            case .sandbox(let id, let generation):
                guard let initiatingScope,
                      initiatingScope.sandboxID == id,
                      initiatingScope.generation == generation
                else {
                    throw Self.mismatchFailure(name)
                }
                ownerKind = "sandbox"
                sandboxID = id
                sandboxGeneration = generation
                initiatingFencingToken = initiatingScope.fencingToken
            }
            guard isValid else {
                throw SandboxRuntimeError.unsupported(
                    "VM \(name) start intent is malformed"
                )
            }
        }

        func matches(
            name: String,
            ownership: LumeVirtualMachineOwnership.Identity,
            owner: LumeVirtualMachineOwnership.Owner
        ) -> Bool {
            // The initiating token remains part of the durable record, but
            // expiry fencing may rotate the current token before reconciliation.
            isValid
                && self.name == name
                && installationID == ownership.installationID
                && matches(owner: owner)
        }

        var isValid: Bool {
            guard schemaVersion == LumeVirtualMachineStartIntent.schemaVersion,
                  SandboxVirtualMachineNamePolicy.isValid(name)
            else {
                return false
            }
            switch ownerKind {
            case "base_template":
                return sandboxID == nil
                    && sandboxGeneration == nil
                    && initiatingFencingToken == nil
            case "sandbox":
                return sandboxID != nil
                    && sandboxGeneration != nil
                    && initiatingFencingToken != nil
            default:
                return false
            }
        }

        private func matches(
            owner: LumeVirtualMachineOwnership.Owner
        ) -> Bool {
            switch owner {
            case .baseTemplate:
                return ownerKind == "base_template"
                    && sandboxID == nil
                    && sandboxGeneration == nil
            case .sandbox(let id, let generation):
                return ownerKind == "sandbox"
                    && sandboxID == id
                    && sandboxGeneration == generation
            }
        }

        private static func mismatchFailure(
            _ name: String
        ) -> SandboxRuntimeError {
            .unsupported(
                "VM \(name) start intent does not match current ownership"
            )
        }
    }
}
