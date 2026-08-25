/// Storage guarantees shared by the native app and the provider CLI.
///
/// Keep this in `ProviderCoreFoundation` so the app can enforce the exact
/// contract without linking the MLX-backed `ProviderCore` target.
public enum ModelDownloadStorageContract {
    /// App-initiated downloads must leave at least 2 GiB free after all
    /// remaining staged bytes have landed.
    public static let appReserveBytes: Int64 = 2 * 1_073_741_824
}
