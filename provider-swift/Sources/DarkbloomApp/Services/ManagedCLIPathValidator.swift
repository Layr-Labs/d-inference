import Foundation
import ProviderCoreFoundation

/// The GUI and launchd use the same descriptor walk and nested/legacy policy.
struct ManagedCLIPathValidator {
    func validatedCLIURL(homeDirectory: URL) -> URL? {
        ManagedProviderCLIPathValidator().validatedCLIURL(homeDirectory: homeDirectory)
    }

    /// Deterministic replacement-race seam; shipping lookup uses no hook.
    func validatedCLIURL(
        homeDirectory: URL,
        betweenValidationPasses: () throws -> Void
    ) rethrows -> URL? {
        try ManagedProviderCLIPathValidator().validatedCLIURL(
            homeDirectory: homeDirectory,
            betweenValidationPasses: betweenValidationPasses
        )
    }
}
