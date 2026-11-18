### Keychain access group in release builds

- Release builds always keep the Secure Enclave key, the SSD cache key and the pairing's link keys in the signed app's keychain access group. `DARKBLOOM_KEYCHAIN_ACCESS_GROUP` now applies to debug builds only.
