@_exported import ProviderCoreFoundation

public enum ProviderCore {
    /// Release identity consumed by CLI output, registration and packaging.
    /// Keep this synchronized with the coordinator's LatestProviderVersion;
    /// scripts/check-release-version.sh verifies the two source values.
    public static let version = "0.9.2"
}
