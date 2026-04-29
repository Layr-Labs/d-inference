use anyhow::{Context, Result, anyhow};
use core_foundation::{
    base::TCFType,
    boolean::CFBoolean,
    dictionary::CFDictionary,
    error::{CFError, CFErrorRef},
    number::CFNumber,
    string::CFString,
};
use crypto_box::{SecretKey, aead::OsRng};
use security_framework::{
    access_control::{ProtectionMode, SecAccessControl},
    item::{ItemClass, ItemSearchOptions, KeyClass, Reference, SearchResult},
    key::{Algorithm, SecKey},
    passwords_options::AccessControlOptions,
};
use security_framework_sys::{
    base::errSecItemNotFound,
    item::{
        kSecAttrAccessControl, kSecAttrAccessGroup, kSecAttrIsPermanent, kSecAttrKeySizeInBits,
        kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom, kSecAttrLabel, kSecAttrTokenID,
        kSecAttrTokenIDSecureEnclave, kSecPrivateKeyAttrs, kSecPublicKeyAttrs,
    },
    key::SecKeyCreateRandomKey,
};

const E2E_KEY_LABEL: &str = "io.darkbloom.provider.e2e-key-agreement.v2";
const E2E_WRAPPED_SECRET_FILENAME: &str = "e2e_key.sealed";
const DEFAULT_KEYCHAIN_ACCESS_GROUP: &str = "SLDQ2GJ6TL.io.darkbloom.provider";

#[cfg(target_os = "macos")]
use std::ffi::{CStr, CString, c_char, c_int, c_void};

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn eigeninference_enclave_create() -> *mut c_void;
    fn eigeninference_enclave_free(identity: *mut c_void);
    fn eigeninference_enclave_public_key_base64(identity: *const c_void) -> *mut c_char;
    fn eigeninference_enclave_sign(
        identity: *const c_void,
        data: *const u8,
        data_len: c_int,
    ) -> *mut c_char;
    fn eigeninference_enclave_create_attestation_full(
        identity: *const c_void,
        encryption_key_base64: *const c_char,
        binary_hash_hex: *const c_char,
    ) -> *mut c_char;
    fn eigeninference_enclave_free_string(ptr: *mut c_char);
    fn eigeninference_provider_identity_load_or_create() -> *mut c_void;
    fn eigeninference_provider_identity_free(identity: *mut c_void);
    fn eigeninference_provider_identity_public_key_base64(identity: *const c_void) -> *mut c_char;
    fn eigeninference_provider_identity_sign(
        identity: *const c_void,
        data: *const u8,
        data_len: c_int,
    ) -> *mut c_char;
}

pub(crate) fn load_existing_x25519_secret() -> Result<Option<[u8; 32]>> {
    let Some(sealed) = read_wrapped_secret_file()? else {
        return Ok(None);
    };
    let private_key = find_secure_enclave_key()?.ok_or_else(|| {
        anyhow!("wrapped text E2E secret exists but the Secure Enclave key is missing")
    })?;
    let secret = unwrap_secret_with_private_key(&private_key, &sealed)
        .context("wrapped text E2E secret is unreadable; refusing silent key rotation")?;
    Ok(Some(secret))
}

/// Ephemeral Secure Enclave P-256 signing key.
///
/// Created fresh on every provider launch. No files on disk, no opaque handle
/// to steal. When this handle is dropped the key is released from the Secure
/// Enclave. Only the hardened provider process holds a reference.
pub struct SecureEnclaveHandle {
    #[cfg(target_os = "macos")]
    ptr: *mut c_void,
    public_key_b64: String,
}

unsafe impl Send for SecureEnclaveHandle {}
unsafe impl Sync for SecureEnclaveHandle {}

impl SecureEnclaveHandle {
    #[cfg(target_os = "macos")]
    pub fn create() -> Result<Self> {
        let ptr = unsafe { eigeninference_enclave_create() };
        if ptr.is_null() {
            return Err(anyhow!("Secure Enclave unavailable or key creation failed"));
        }

        let pk_ptr = unsafe { eigeninference_enclave_public_key_base64(ptr) };
        if pk_ptr.is_null() {
            unsafe { eigeninference_enclave_free(ptr) };
            return Err(anyhow!("failed to retrieve Secure Enclave public key"));
        }
        let public_key_b64 = unsafe { CStr::from_ptr(pk_ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { eigeninference_enclave_free_string(pk_ptr) };

        Ok(Self {
            ptr,
            public_key_b64,
        })
    }

    #[cfg(not(target_os = "macos"))]
    pub fn create() -> Result<Self> {
        Err(anyhow!("Secure Enclave not available on this platform"))
    }

    pub fn public_key_base64(&self) -> &str {
        &self.public_key_b64
    }

    #[cfg(target_os = "macos")]
    pub fn sign(&self, data: &[u8]) -> Result<String> {
        use anyhow::Context;
        let data_len: c_int = data.len().try_into().context("data too large for FFI")?;
        let sig_ptr = unsafe { eigeninference_enclave_sign(self.ptr, data.as_ptr(), data_len) };
        if sig_ptr.is_null() {
            return Err(anyhow!("Secure Enclave signing failed"));
        }
        let sig = unsafe { CStr::from_ptr(sig_ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { eigeninference_enclave_free_string(sig_ptr) };
        Ok(sig)
    }

    #[cfg(not(target_os = "macos"))]
    pub fn sign(&self, _data: &[u8]) -> Result<String> {
        Err(anyhow!("Secure Enclave not available on this platform"))
    }

    #[cfg(target_os = "macos")]
    pub fn create_attestation(
        &self,
        encryption_key_b64: &str,
        binary_hash: Option<&str>,
    ) -> Result<Box<serde_json::value::RawValue>> {
        use anyhow::Context;
        let enc_key_c =
            CString::new(encryption_key_b64).context("encryption key contains null byte")?;
        let hash_c = binary_hash
            .map(|h| CString::new(h).context("binary hash contains null byte"))
            .transpose()?;

        let json_ptr = unsafe {
            eigeninference_enclave_create_attestation_full(
                self.ptr,
                enc_key_c.as_ptr(),
                hash_c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
            )
        };
        if json_ptr.is_null() {
            return Err(anyhow!("attestation generation failed"));
        }
        let json_str = unsafe { CStr::from_ptr(json_ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { eigeninference_enclave_free_string(json_ptr) };

        serde_json::value::RawValue::from_string(json_str).context("attestation JSON is not valid")
    }

    #[cfg(not(target_os = "macos"))]
    pub fn create_attestation(
        &self,
        _encryption_key_b64: &str,
        _binary_hash: Option<&str>,
    ) -> Result<Box<serde_json::value::RawValue>> {
        Err(anyhow!("Secure Enclave not available on this platform"))
    }
}

#[cfg(target_os = "macos")]
impl Drop for SecureEnclaveHandle {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { eigeninference_enclave_free(self.ptr) };
        }
    }
}

/// Persistent provider-bound identity.
///
/// This key is created once as a permanent Secure Enclave key under the
/// Darkbloom provider keychain access group. It is the fork-resistant root used
/// to bind a WebSocket X25519 key and runtime claims to a signed provider.
pub struct ProviderIdentityHandle {
    #[cfg(target_os = "macos")]
    ptr: *mut c_void,
    public_key_b64: String,
}

unsafe impl Send for ProviderIdentityHandle {}
unsafe impl Sync for ProviderIdentityHandle {}

impl ProviderIdentityHandle {
    #[cfg(target_os = "macos")]
    pub fn load_or_create() -> Result<Self> {
        let ptr = unsafe { eigeninference_provider_identity_load_or_create() };
        if ptr.is_null() {
            return Err(anyhow!(
                "provider-bound identity unavailable; signed release build with keychain entitlement required"
            ));
        }

        let pk_ptr = unsafe { eigeninference_provider_identity_public_key_base64(ptr) };
        if pk_ptr.is_null() {
            unsafe { eigeninference_provider_identity_free(ptr) };
            return Err(anyhow!("failed to retrieve provider identity public key"));
        }
        let public_key_b64 = unsafe { CStr::from_ptr(pk_ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { eigeninference_enclave_free_string(pk_ptr) };

        Ok(Self {
            ptr,
            public_key_b64,
        })
    }

    #[cfg(not(target_os = "macos"))]
    pub fn load_or_create() -> Result<Self> {
        Err(anyhow!(
            "provider-bound identity is only available on macOS Secure Enclave"
        ))
    }

    pub fn public_key_base64(&self) -> &str {
        &self.public_key_b64
    }

    #[cfg(target_os = "macos")]
    pub fn sign(&self, data: &[u8]) -> Result<String> {
        let data_len: c_int = data.len().try_into().context("data too large for FFI")?;
        let sig_ptr =
            unsafe { eigeninference_provider_identity_sign(self.ptr, data.as_ptr(), data_len) };
        if sig_ptr.is_null() {
            return Err(anyhow!("provider identity signing failed"));
        }
        let sig = unsafe { CStr::from_ptr(sig_ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe { eigeninference_enclave_free_string(sig_ptr) };
        Ok(sig)
    }

    #[cfg(not(target_os = "macos"))]
    pub fn sign(&self, _data: &[u8]) -> Result<String> {
        Err(anyhow!(
            "provider-bound identity is only available on macOS Secure Enclave"
        ))
    }
}

#[cfg(target_os = "macos")]
impl Drop for ProviderIdentityHandle {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { eigeninference_provider_identity_free(self.ptr) };
        }
    }
}

/// Check that no legacy key files exist in `~/.darkbloom/`.
///
/// Returns a list of legacy files that still exist. Empty means clean.
pub fn legacy_key_files_present() -> Vec<std::path::PathBuf> {
    let Some(home) = dirs::home_dir() else {
        return Vec::new();
    };
    LEGACY_KEY_FILES
        .iter()
        .map(|f| home.join(f))
        .filter(|p| p.exists())
        .collect()
}

const LEGACY_KEY_FILES: &[&str] = &[
    ".darkbloom/enclave_key.data",
    ".darkbloom/e2e_key.data",
    ".darkbloom/e2e_key.provisioned",
    ".darkbloom/e2e_key.sealed",
    ".darkbloom/node_key",
    ".darkbloom/enclave_e2e_ka.data",
    ".dginf/enclave_e2e_ka.data",
    ".dginf/node_key",
    ".eigeninference/enclave_e2e_ka.data",
    ".eigeninference/node_key",
];

pub fn cleanup_legacy_key_files() {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    for file in LEGACY_KEY_FILES {
        let path = home.join(file);
        if path.exists() {
            match std::fs::remove_file(&path) {
                Ok(()) => tracing::info!("Cleaned up legacy key file: {}", path.display()),
                Err(e) => tracing::warn!("Failed to clean up {}: {e}", path.display()),
            }
        }
    }
}

pub(crate) fn load_or_create_x25519_secret() -> Result<[u8; 32]> {
    if let Some(secret) = load_existing_x25519_secret()? {
        return Ok(secret);
    }

    let private_key = load_or_create_secure_enclave_key()?;
    let secret = SecretKey::generate(&mut OsRng).to_bytes();
    let sealed = wrap_secret_with_public_key(&private_key, &secret)?;
    write_wrapped_secret_file(&sealed)?;
    Ok(secret)
}

pub(crate) fn delete_persistent_key() -> Result<()> {
    if let Some(key) = find_secure_enclave_key()? {
        key.delete()
            .map_err(|err| anyhow!("failed to delete Secure Enclave E2E key: {err}"))?;
    }
    delete_wrapped_secret_file()?;
    Ok(())
}

fn load_or_create_secure_enclave_key() -> Result<SecKey> {
    if let Some(existing) = find_secure_enclave_key()? {
        return Ok(existing);
    }

    create_secure_enclave_key()
}

fn find_secure_enclave_key() -> Result<Option<SecKey>> {
    let mut search = ItemSearchOptions::new();
    search
        .class(ItemClass::key())
        .key_class(KeyClass::private())
        .label(E2E_KEY_LABEL)
        .access_group(&keychain_access_group())
        .load_refs(true)
        .limit(1);

    let results = match search.search() {
        Ok(results) => results,
        Err(err) if err.code() == errSecItemNotFound => return Ok(None),
        Err(err) => {
            return Err(anyhow!(
                "failed to query Secure Enclave E2E key from keychain: {err}"
            ));
        }
    };

    for result in results {
        if let SearchResult::Ref(Reference::Key(key)) = result {
            return Ok(Some(key));
        }
    }

    Ok(None)
}

fn create_secure_enclave_key() -> Result<SecKey> {
    let access_control = SecAccessControl::create_with_protection(
        Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
        AccessControlOptions::PRIVATE_KEY_USAGE.bits(),
    )
    .map_err(|err| anyhow!("failed to create Secure Enclave access control: {err}"))?;

    let access_group = CFString::new(&keychain_access_group());
    let label = CFString::new(E2E_KEY_LABEL);
    let key_size_bits = CFNumber::from(256i32).into_CFType();

    let private_attrs = CFDictionary::from_CFType_pairs(&[
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrIsPermanent) },
            CFBoolean::true_value().into_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrAccessControl) },
            access_control.as_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrAccessGroup) },
            access_group.as_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrLabel) },
            label.as_CFType(),
        ),
    ]);

    let public_attrs = CFDictionary::from_CFType_pairs(&[
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrIsPermanent) },
            CFBoolean::true_value().into_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrAccessGroup) },
            access_group.as_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrLabel) },
            label.as_CFType(),
        ),
    ]);

    let attrs = CFDictionary::from_CFType_pairs(&[
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrKeyType) },
            unsafe { CFString::wrap_under_get_rule(kSecAttrKeyTypeECSECPrimeRandom) }.into_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrKeySizeInBits) },
            key_size_bits,
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecAttrTokenID) },
            unsafe { CFString::wrap_under_get_rule(kSecAttrTokenIDSecureEnclave) }.into_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecPrivateKeyAttrs) },
            private_attrs.as_CFType(),
        ),
        (
            unsafe { CFString::wrap_under_get_rule(kSecPublicKeyAttrs) },
            public_attrs.as_CFType(),
        ),
    ]);

    let mut error: CFErrorRef = std::ptr::null_mut();
    let key_ref = unsafe { SecKeyCreateRandomKey(attrs.as_concrete_TypeRef(), &mut error) };
    if !error.is_null() {
        let error = unsafe { CFError::wrap_under_create_rule(error) };
        return Err(anyhow!(
            "failed to create Secure Enclave E2E key; signed release build with keychain entitlement required: {error:?}"
        ));
    }
    if key_ref.is_null() {
        return Err(anyhow!(
            "failed to create Secure Enclave E2E key: Security.framework returned null"
        ));
    }

    Ok(unsafe { SecKey::wrap_under_create_rule(key_ref) })
}

fn wrap_secret_with_public_key(private_key: &SecKey, secret: &[u8; 32]) -> Result<Vec<u8>> {
    let public_key = private_key.public_key().ok_or_else(|| {
        anyhow!("Secure Enclave E2E key does not expose a public key for wrapping")
    })?;
    public_key
        .encrypt_data(Algorithm::ECIESEncryptionStandardX963SHA256AESGCM, secret)
        .map_err(|err| {
            anyhow!("failed to seal X25519 secret with Secure Enclave public key: {err}")
        })
}

fn unwrap_secret_with_private_key(private_key: &SecKey, sealed: &[u8]) -> Result<[u8; 32]> {
    let secret = private_key
        .decrypt_data(Algorithm::ECIESEncryptionStandardX963SHA256AESGCM, sealed)
        .map_err(|err| anyhow!("failed to unseal X25519 secret with Secure Enclave key: {err}"))?;

    if secret.len() != 32 {
        return Err(anyhow!(
            "unsealed X25519 secret was {} bytes, expected 32",
            secret.len()
        ));
    }

    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&secret);
    Ok(bytes)
}

fn write_wrapped_secret_file(sealed: &[u8]) -> Result<()> {
    let path = wrapped_secret_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(&path, sealed)
        .with_context(|| format!("failed to write wrapped E2E secret to {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod {}", path.display()))?;
    }
    Ok(())
}

fn read_wrapped_secret_file() -> Result<Option<Vec<u8>>> {
    let path = wrapped_secret_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let data = std::fs::read(&path)
        .with_context(|| format!("failed to read wrapped E2E secret from {}", path.display()))?;
    Ok(Some(data))
}

fn delete_wrapped_secret_file() -> Result<()> {
    let path = wrapped_secret_path()?;
    if path.exists() {
        std::fs::remove_file(&path)
            .with_context(|| format!("failed to remove wrapped E2E secret {}", path.display()))?;
    }
    Ok(())
}

fn wrapped_secret_path() -> Result<std::path::PathBuf> {
    let home =
        dirs::home_dir().context("could not determine home directory for wrapped E2E key")?;
    Ok(home.join(".darkbloom").join(E2E_WRAPPED_SECRET_FILENAME))
}

fn keychain_access_group() -> String {
    std::env::var("DARKBLOOM_KEYCHAIN_ACCESS_GROUP")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_KEYCHAIN_ACCESS_GROUP.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    // --- Ephemeral SE handle tests (macOS only) ---

    #[cfg(target_os = "macos")]
    #[test]
    fn test_create_ephemeral_handle() {
        let handle = SecureEnclaveHandle::create().expect("SE should be available");
        let pk = handle.public_key_base64();
        assert!(!pk.is_empty(), "public key must be non-empty");
        // Base64 of 64 raw P-256 bytes = 88 chars
        assert_eq!(
            pk.len(),
            88,
            "P-256 raw public key base64 should be 88 chars"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_ephemeral_handles_produce_different_keys() {
        let h1 = SecureEnclaveHandle::create().unwrap();
        let h2 = SecureEnclaveHandle::create().unwrap();
        assert_ne!(
            h1.public_key_base64(),
            h2.public_key_base64(),
            "each ephemeral handle must produce a unique key"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_ephemeral_handle_sign() {
        let handle = SecureEnclaveHandle::create().unwrap();
        let sig = handle.sign(b"test challenge data").unwrap();
        assert!(!sig.is_empty(), "signature must be non-empty");
        // DER-encoded ECDSA P-256 signature is ~70-72 bytes, base64 ≈ 96 chars
        assert!(sig.len() > 50, "base64 DER signature should be substantial");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_ephemeral_handle_sign_different_data_different_sigs() {
        let handle = SecureEnclaveHandle::create().unwrap();
        let sig1 = handle.sign(b"message alpha").unwrap();
        let sig2 = handle.sign(b"message beta").unwrap();
        assert_ne!(
            sig1, sig2,
            "different inputs must produce different signatures"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_ephemeral_handle_creates_attestation() {
        let handle = SecureEnclaveHandle::create().unwrap();
        let enc_key =
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &[0u8; 32]);
        let att = handle
            .create_attestation(&enc_key, Some("abcdef1234567890"))
            .expect("attestation should succeed");
        let json = att.get();
        assert!(
            json.contains("publicKey"),
            "attestation must contain publicKey"
        );
        assert!(
            json.contains("signature"),
            "attestation must contain signature"
        );
        assert!(
            json.contains("encryptionPublicKey"),
            "attestation must bind encryption key"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_ephemeral_handle_attestation_without_binary_hash() {
        let handle = SecureEnclaveHandle::create().unwrap();
        let enc_key =
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &[1u8; 32]);
        let att = handle
            .create_attestation(&enc_key, None)
            .expect("attestation without binary hash should succeed");
        let json = att.get();
        assert!(json.contains("publicKey"));
        assert!(json.contains("signature"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_no_key_files_created_on_disk() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", tmp.path()) };

        let handle = SecureEnclaveHandle::create().unwrap();
        let _sig = handle.sign(b"test").unwrap();
        let _att = handle.create_attestation("dGVzdA==", None).unwrap();
        drop(handle);

        // Verify no key files were written to the temp HOME
        for file in LEGACY_KEY_FILES {
            let path = tmp.path().join(file);
            assert!(!path.exists(), "ephemeral handle must not create {file}");
        }

        // Also check that no .darkbloom directory was created at all
        assert!(
            !tmp.path().join(".darkbloom").exists(),
            "ephemeral handle must not create ~/.darkbloom/"
        );

        match old_home {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    // --- Legacy cleanup tests (all platforms) ---

    #[test]
    fn test_cleanup_legacy_key_files_removes_all_known_files() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();

        // Create all legacy files
        for file in LEGACY_KEY_FILES {
            let path = home.join(file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"legacy-data").unwrap();
        }

        // Verify they exist
        for file in LEGACY_KEY_FILES {
            assert!(
                home.join(file).exists(),
                "{file} should exist before cleanup"
            );
        }

        let old_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", home) };

        cleanup_legacy_key_files();

        match old_home {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        // All should be gone
        for file in LEGACY_KEY_FILES {
            assert!(
                !home.join(file).exists(),
                "{file} should be removed after cleanup"
            );
        }
    }

    #[test]
    fn test_cleanup_legacy_key_files_noop_when_no_files() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", tmp.path()) };

        // Should not panic even with no files
        cleanup_legacy_key_files();

        match old_home {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    #[test]
    fn test_legacy_key_files_present_detects_files() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();

        let old_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", home) };

        // No files → empty
        assert!(
            legacy_key_files_present().is_empty(),
            "should detect no legacy files in clean dir"
        );

        // Create one legacy file
        let legacy_path = home.join(".darkbloom/enclave_key.data");
        std::fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        std::fs::write(&legacy_path, b"stale").unwrap();

        let found = legacy_key_files_present();
        assert_eq!(found.len(), 1, "should detect exactly one legacy file");
        assert!(found[0].ends_with("enclave_key.data"));

        match old_home {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    #[test]
    fn test_cleanup_then_present_returns_empty() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();

        // Create some legacy files
        for file in &LEGACY_KEY_FILES[..3] {
            let path = home.join(file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"old").unwrap();
        }

        let old_home = std::env::var_os("HOME");
        unsafe { std::env::set_var("HOME", home) };

        assert!(!legacy_key_files_present().is_empty());
        cleanup_legacy_key_files();
        assert!(
            legacy_key_files_present().is_empty(),
            "after cleanup, no legacy files should remain"
        );

        match old_home {
            Some(v) => unsafe { std::env::set_var("HOME", v) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    // --- Ephemeral X25519 tests ---

    #[test]
    fn test_ephemeral_x25519_keys_differ_each_generate() {
        let kp1 = crate::crypto::NodeKeyPair::generate();
        let kp2 = crate::crypto::NodeKeyPair::generate();
        assert_ne!(
            kp1.public_key_base64(),
            kp2.public_key_base64(),
            "each generate() must produce a unique X25519 key"
        );
    }
}
