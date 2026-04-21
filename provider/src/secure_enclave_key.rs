use anyhow::{Result, anyhow};

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
