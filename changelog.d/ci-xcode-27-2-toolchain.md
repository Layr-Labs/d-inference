### Provider builds use Xcode 27.2 (SDK 27.2, Swift 6.4.2)

- Release builds, release qualification and signing accept only SDK 27.2 and Apple Swift 6.4.2 (Xcode 27.2). `release-provider.yml` and `provider-signing-validation.yml` set `DARKBLOOM_PROVIDER_TOOLCHAIN=release`, as do master and dispatched SDK 27 release preparation.
- Provider CI accepts SDK 27.2, or SDK 27.0 (Xcode 27.1), with Swift 6.4 or 6.4.x. SDK 27.0 stays only while the Darkbloom Sandbox production macOS CI base is on Xcode 27.1.
- The toolchain step tries the image's Xcode, then each installed Xcode, and takes the first with SDK 27.2. When it selects another Xcode than the image's, it exports `DEVELOPER_DIR`, so Metal, `xcodebuild` and signing use the same Xcode. When no Xcode qualifies, it names the installed ones.
- `PROVIDER_SDK_VERSION` is the SDK that was selected, not a fixed 27.0. A resumed release signs an unsigned build only when that build linked SDK 27.2.
- `mise.toml` pins Swift 6.4.2.
