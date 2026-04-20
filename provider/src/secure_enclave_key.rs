use anyhow::{Context, Result, anyhow};
use security_framework::{
    item::{ItemClass, ItemSearchOptions, KeyClass, Reference, SearchResult},
    key::SecKey,
};
use security_framework_sys::base::errSecItemNotFound;
use std::{
    ffi::{c_int, c_void},
    path::{Path, PathBuf},
};

const E2E_KEY_LABEL: &str = "io.darkbloom.provider.e2e-key-agreement.v2";
const E2E_IDENTITY_FILENAME: &str = "e2e_key.data";
const E2E_IDENTITY_MARKER_FILENAME: &str = "e2e_key.provisioned";
const LEGACY_IDENTITY_FILENAME: &str = "enclave_e2e_ka.data";
const LEGACY_WRAPPED_SECRET_FILENAME: &str = "e2e_key.sealed";
const LEGACY_PLAINTEXT_NODE_KEY_FILENAME: &str = "node_key";
const DEFAULT_KEYCHAIN_ACCESS_GROUP: &str = "SLDQ2GJ6TL.io.darkbloom.provider";

unsafe extern "C" {
    fn eigeninference_enclave_free(identity: *mut c_void);
    fn eigeninference_enclave_key_agreement_create() -> *mut c_void;
    fn eigeninference_enclave_key_agreement_load(data: *const u8, data_len: c_int) -> *mut c_void;
    fn eigeninference_enclave_key_agreement_data_representation(
        identity: *const c_void,
        buffer: *mut u8,
        buffer_len: c_int,
    ) -> c_int;
    fn eigeninference_enclave_key_agreement_derive_x25519_secret(
        identity: *const c_void,
        buffer: *mut u8,
        buffer_len: c_int,
    ) -> c_int;
}

struct KeyAgreementHandle(*mut c_void);

impl Drop for KeyAgreementHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { eigeninference_enclave_free(self.0) };
        }
    }
}

impl KeyAgreementHandle {
    fn create() -> Result<Self> {
        let ptr = unsafe { eigeninference_enclave_key_agreement_create() };
        if ptr.is_null() {
            return Err(anyhow!(
                "Secure Enclave key-agreement identity creation returned null"
            ));
        }
        Ok(Self(ptr))
    }

    fn load(data: &[u8]) -> Result<Self> {
        let data_len: c_int = data
            .len()
            .try_into()
            .context("Secure Enclave identity blob exceeded c_int length")?;
        let ptr = unsafe { eigeninference_enclave_key_agreement_load(data.as_ptr(), data_len) };
        if ptr.is_null() {
            return Err(anyhow!(
                "Secure Enclave key-agreement identity reload returned null"
            ));
        }
        Ok(Self(ptr))
    }

    fn data_representation(&self) -> Result<Vec<u8>> {
        let required = unsafe {
            eigeninference_enclave_key_agreement_data_representation(
                self.0,
                std::ptr::null_mut(),
                0,
            )
        };
        if required <= 0 {
            return Err(anyhow!(
                "Secure Enclave key-agreement identity returned invalid blob length {required}"
            ));
        }

        let mut data = vec![0u8; required as usize];
        let written = unsafe {
            eigeninference_enclave_key_agreement_data_representation(
                self.0,
                data.as_mut_ptr(),
                required,
            )
        };
        if written != required {
            return Err(anyhow!(
                "Secure Enclave key-agreement identity blob write returned {written}, expected {required}"
            ));
        }
        Ok(data)
    }

    fn derive_x25519_secret(&self) -> Result<[u8; 32]> {
        let required = unsafe {
            eigeninference_enclave_key_agreement_derive_x25519_secret(
                self.0,
                std::ptr::null_mut(),
                0,
            )
        };
        if required != 32 {
            return Err(anyhow!(
                "Secure Enclave key-agreement derivation returned {required} bytes, expected 32"
            ));
        }

        let mut secret = [0u8; 32];
        let written = unsafe {
            eigeninference_enclave_key_agreement_derive_x25519_secret(
                self.0,
                secret.as_mut_ptr(),
                required,
            )
        };
        if written != 32 {
            return Err(anyhow!(
                "Secure Enclave key-agreement derivation wrote {written} bytes, expected 32"
            ));
        }
        Ok(secret)
    }
}

pub(crate) fn load_existing_x25519_secret() -> Result<Option<[u8; 32]>> {
    let identity_path = key_agreement_identity_path()?;
    if identity_path.exists() {
        let secret = load_x25519_secret_from_identity_file(&identity_path)?;
        mark_x25519_identity_provisioned()?;
        purge_disallowed_legacy_transport_material()?;
        return Ok(Some(secret));
    }

    if let Some(legacy_identity_path) = first_existing_legacy_identity_path()? {
        let secret = load_x25519_secret_from_legacy_identity_file(&legacy_identity_path)?;
        purge_disallowed_legacy_transport_material()?;
        return Ok(Some(secret));
    }

    if read_legacy_wrapped_secret_file()?.is_some() {
        return Err(anyhow!(
            "legacy wrapped E2E key {} must be rotated; refusing to import potentially compromised legacy key material",
            legacy_wrapped_secret_path()?.display()
        ));
    }

    if let Some(legacy_node_key_path) = first_existing_legacy_plaintext_node_key_path()? {
        return Err(anyhow!(
            "legacy plaintext E2E key {} cannot be silently migrated; refusing key rotation",
            legacy_node_key_path.display()
        ));
    }

    if has_x25519_identity_marker()? {
        return Err(anyhow!(
            "canonical E2E identity {} is missing; refusing silent key rotation",
            identity_path.display()
        ));
    }

    Ok(None)
}

pub(crate) fn load_or_create_x25519_secret() -> Result<[u8; 32]> {
    if let Some(secret) = load_existing_x25519_secret()? {
        return Ok(secret);
    }

    let identity = KeyAgreementHandle::create()
        .context("failed to create Secure Enclave-backed E2E identity")?;
    let data = identity
        .data_representation()
        .context("failed to serialize Secure Enclave-backed E2E identity")?;
    write_key_agreement_identity_file(&data)?;
    mark_x25519_identity_provisioned()?;
    identity
        .derive_x25519_secret()
        .context("failed to derive X25519 E2E secret from Secure Enclave identity")
}

pub(crate) fn delete_persistent_key() -> Result<()> {
    delete_key_agreement_identity_file()?;
    delete_x25519_identity_marker()?;
    if let Some(key) = find_legacy_secure_enclave_key()? {
        key.delete()
            .map_err(|err| anyhow!("failed to delete legacy Secure Enclave E2E key: {err}"))?;
    }
    delete_legacy_wrapped_secret_file()?;
    Ok(())
}

pub(crate) fn has_persisted_x25519_identity() -> Result<bool> {
    Ok(key_agreement_identity_path()?.exists())
}

fn load_x25519_secret_from_identity_file(path: &Path) -> Result<[u8; 32]> {
    let data = std::fs::read(path).with_context(|| {
        format!(
            "failed to read Secure Enclave E2E identity {}",
            path.display()
        )
    })?;
    let identity = KeyAgreementHandle::load(&data).context(
        "stored Secure Enclave E2E identity is unreadable; refusing silent key rotation",
    )?;
    identity
        .derive_x25519_secret()
        .context("failed to derive X25519 E2E secret from persisted Secure Enclave identity")
}

fn load_x25519_secret_from_legacy_identity_file(path: &Path) -> Result<[u8; 32]> {
    let data = std::fs::read(path).with_context(|| {
        format!(
            "failed to read legacy Secure Enclave E2E identity {}",
            path.display()
        )
    })?;
    let identity = KeyAgreementHandle::load(&data).context(
        "legacy Secure Enclave E2E identity is unreadable; refusing silent key rotation",
    )?;
    if !has_persisted_x25519_identity()? {
        write_key_agreement_identity_file(&data)?;
    }
    mark_x25519_identity_provisioned()?;
    identity
        .derive_x25519_secret()
        .context("failed to derive X25519 E2E secret from legacy Secure Enclave identity")
}

fn write_key_agreement_identity_file(data: &[u8]) -> Result<()> {
    let path = key_agreement_identity_path()?;
    write_private_file(&path, data)
}

fn delete_key_agreement_identity_file() -> Result<()> {
    let path = key_agreement_identity_path()?;
    delete_private_file(&path)
}

fn key_agreement_identity_path() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not determine home directory for E2E key")?;
    Ok(home.join(".darkbloom").join(E2E_IDENTITY_FILENAME))
}

fn x25519_identity_marker_path() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not determine home directory for E2E key marker")?;
    Ok(home.join(".darkbloom").join(E2E_IDENTITY_MARKER_FILENAME))
}

fn has_x25519_identity_marker() -> Result<bool> {
    Ok(x25519_identity_marker_path()?.exists())
}

fn mark_x25519_identity_provisioned() -> Result<()> {
    let path = x25519_identity_marker_path()?;
    write_private_file(&path, b"provisioned")
}

fn delete_x25519_identity_marker() -> Result<()> {
    let path = x25519_identity_marker_path()?;
    delete_private_file(&path)
}

fn find_legacy_secure_enclave_key() -> Result<Option<SecKey>> {
    let mut search = ItemSearchOptions::new();
    search
        .class(ItemClass::key())
        .key_class(KeyClass::private())
        .label(E2E_KEY_LABEL)
        .access_group(&keychain_access_group())
        .ignore_legacy_keychains()
        .load_refs(true)
        .limit(1);

    let results = match search.search() {
        Ok(results) => results,
        Err(err) if err.code() == errSecItemNotFound => return Ok(None),
        Err(err) => {
            return Err(anyhow!(
                "failed to query legacy Secure Enclave E2E key from keychain: {err}"
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

fn read_legacy_wrapped_secret_file() -> Result<Option<Vec<u8>>> {
    let path = legacy_wrapped_secret_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let data = std::fs::read(&path).with_context(|| {
        format!(
            "failed to read legacy wrapped E2E secret from {}",
            path.display()
        )
    })?;
    Ok(Some(data))
}

fn delete_legacy_wrapped_secret_file() -> Result<()> {
    let path = legacy_wrapped_secret_path()?;
    delete_private_file(&path)
}

fn purge_disallowed_legacy_transport_material() -> Result<()> {
    if let Ok(Some(key)) = find_legacy_secure_enclave_key() {
        key.delete()
            .map_err(|err| anyhow!("failed to delete legacy Secure Enclave E2E key: {err}"))?;
    }
    delete_legacy_wrapped_secret_file()?;
    for path in legacy_plaintext_node_key_paths()? {
        delete_private_file(&path)?;
    }
    Ok(())
}

fn legacy_wrapped_secret_path() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not determine home directory for legacy E2E key")?;
    Ok(home.join(".darkbloom").join(LEGACY_WRAPPED_SECRET_FILENAME))
}

fn first_existing_legacy_identity_path() -> Result<Option<PathBuf>> {
    Ok(legacy_identity_paths()?
        .into_iter()
        .find(|path| path.exists()))
}

fn legacy_identity_paths() -> Result<Vec<PathBuf>> {
    let home =
        dirs::home_dir().context("could not determine home directory for legacy E2E identity")?;
    Ok([".darkbloom", ".dginf", ".eigeninference"]
        .into_iter()
        .map(|dir| home.join(dir).join(LEGACY_IDENTITY_FILENAME))
        .collect())
}

fn first_existing_legacy_plaintext_node_key_path() -> Result<Option<PathBuf>> {
    Ok(legacy_plaintext_node_key_paths()?
        .into_iter()
        .find(|path| path.exists()))
}

fn legacy_plaintext_node_key_paths() -> Result<Vec<PathBuf>> {
    let home = dirs::home_dir()
        .context("could not determine home directory for legacy plaintext E2E key")?;
    Ok([".darkbloom", ".dginf", ".eigeninference"]
        .into_iter()
        .map(|dir| home.join(dir).join(LEGACY_PLAINTEXT_NODE_KEY_FILENAME))
        .collect())
}

fn write_private_file(path: &Path, data: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(path, data)
        .with_context(|| format!("failed to write private file {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod {}", path.display()))?;
    }
    Ok(())
}

fn delete_private_file(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to remove private file {}", path.display()))?;
    }
    Ok(())
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

    #[test]
    fn test_load_existing_x25519_secret_refuses_legacy_plaintext_node_key() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let legacy_node_key = tmp.path().join(".darkbloom/node_key");
        std::fs::create_dir_all(legacy_node_key.parent().unwrap()).unwrap();
        std::fs::write(&legacy_node_key, [7u8; 32]).unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let err = load_existing_x25519_secret()
            .expect_err("plaintext legacy node key should fail closed");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert!(
            err.to_string().contains("refusing key rotation"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn test_load_existing_x25519_secret_refuses_legacy_wrapped_secret() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let wrapped_secret = tmp.path().join(".darkbloom/e2e_key.sealed");
        std::fs::create_dir_all(wrapped_secret.parent().unwrap()).unwrap();
        std::fs::write(&wrapped_secret, b"legacy-sealed-secret").unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let err =
            load_existing_x25519_secret().expect_err("legacy wrapped secret should fail closed");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert!(
            err.to_string().contains("must be rotated"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn test_load_existing_x25519_secret_migrates_legacy_identity_file() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let legacy_identity = tmp.path().join(".darkbloom/enclave_e2e_ka.data");
        std::fs::create_dir_all(legacy_identity.parent().unwrap()).unwrap();

        let identity = KeyAgreementHandle::create().expect("create legacy key agreement identity");
        let data = identity
            .data_representation()
            .expect("serialize legacy key agreement identity");
        let expected_secret = identity
            .derive_x25519_secret()
            .expect("derive secret from legacy identity");
        std::fs::write(&legacy_identity, &data).unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let loaded_secret = load_existing_x25519_secret()
            .expect("legacy identity should load")
            .expect("legacy identity should produce a secret");
        let canonical_identity = tmp.path().join(".darkbloom/e2e_key.data");
        let canonical_secret = load_x25519_secret_from_identity_file(&canonical_identity)
            .expect("canonical identity should be readable");
        let provisioned_marker = tmp.path().join(".darkbloom/e2e_key.provisioned");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert_eq!(loaded_secret, expected_secret);
        assert_eq!(canonical_secret, expected_secret);
        assert!(
            provisioned_marker.exists(),
            "provisioned marker should be written"
        );
    }

    #[test]
    fn test_load_or_create_x25519_secret_persists_and_reloads_canonical_identity() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        let created_secret =
            load_or_create_x25519_secret().expect("should create canonical identity");
        let canonical_identity = tmp.path().join(".darkbloom/e2e_key.data");
        let provisioned_marker = tmp.path().join(".darkbloom/e2e_key.provisioned");
        assert!(
            canonical_identity.exists(),
            "canonical identity file should be written"
        );
        assert!(
            provisioned_marker.exists(),
            "provisioned marker should be written"
        );

        let loaded_secret = load_existing_x25519_secret()
            .expect("canonical identity should load")
            .expect("canonical identity should exist");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert_eq!(loaded_secret, created_secret);
    }

    #[test]
    fn test_load_or_create_x25519_secret_refuses_missing_canonical_after_provisioning() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        load_or_create_x25519_secret().expect("should create canonical identity");
        std::fs::remove_file(tmp.path().join(".darkbloom/e2e_key.data"))
            .expect("remove canonical identity");

        let err = load_or_create_x25519_secret()
            .expect_err("missing canonical identity after provisioning should fail");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert!(
            err.to_string().contains("refusing silent key rotation"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn test_load_existing_x25519_secret_purges_stale_legacy_transport_files_when_canonical_exists()
    {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let canonical_identity = tmp.path().join(".darkbloom/e2e_key.data");
        let wrapped_secret = tmp.path().join(".darkbloom/e2e_key.sealed");
        let legacy_node_key = tmp.path().join(".darkbloom/node_key");
        std::fs::create_dir_all(canonical_identity.parent().unwrap()).unwrap();

        let identity =
            KeyAgreementHandle::create().expect("create canonical key agreement identity");
        let data = identity
            .data_representation()
            .expect("serialize canonical key agreement identity");
        std::fs::write(&canonical_identity, &data).unwrap();
        std::fs::write(&wrapped_secret, b"legacy-sealed-secret").unwrap();
        std::fs::write(&legacy_node_key, [7u8; 32]).unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", tmp.path());
        }

        load_existing_x25519_secret()
            .expect("canonical identity should load")
            .expect("canonical identity should exist");

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }

        assert!(
            !wrapped_secret.exists(),
            "stale wrapped secret should be purged"
        );
        assert!(
            !legacy_node_key.exists(),
            "stale legacy node key should be purged"
        );
    }
}
