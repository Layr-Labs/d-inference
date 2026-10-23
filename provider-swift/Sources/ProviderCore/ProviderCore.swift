@_exported import ProviderCoreFoundation
@_exported import ProviderBuildEnvironment

public enum ProviderCore {
    /// Release identity consumed by CLI output, registration and packaging.
    /// scripts/check-release-version.sh verifies this provider-owned identity
    /// against the requested release tag and reported binary version.
    public static let version = "0.10.0"
}
