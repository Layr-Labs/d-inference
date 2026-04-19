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
    use security_framework::key::{GenerateKeyOptions, KeyType, Token};

    fn generate_software_ec_key() -> SecKey {
        let mut options = GenerateKeyOptions::default();
        options
            .set_key_type(KeyType::ec())
            .set_size_in_bits(256)
            .set_token(Token::Software);
        SecKey::new(&options).expect("software EC key generation should succeed")
    }

    #[test]
    fn test_wrap_unwrap_round_trip() {
        let key = generate_software_ec_key();
        let secret = SecretKey::generate(&mut OsRng).to_bytes();
        let sealed = wrap_secret_with_public_key(&key, &secret).expect("wrap should succeed");
        let unsealed = unwrap_secret_with_private_key(&key, &sealed).expect("unwrap should work");
        assert_eq!(unsealed, secret);
    }

    #[test]
    fn test_wrap_is_not_plaintext() {
        let key = generate_software_ec_key();
        let secret = SecretKey::generate(&mut OsRng).to_bytes();
        let sealed = wrap_secret_with_public_key(&key, &secret).expect("wrap should succeed");
        assert_ne!(sealed, secret);
    }

    #[test]
    fn test_unwrap_with_wrong_key_fails() {
        let right_key = generate_software_ec_key();
        let wrong_key = generate_software_ec_key();
        let secret = SecretKey::generate(&mut OsRng).to_bytes();
        let sealed = wrap_secret_with_public_key(&right_key, &secret).expect("wrap succeeds");
        let err = unwrap_secret_with_private_key(&wrong_key, &sealed).unwrap_err();
        assert!(err.to_string().contains("failed to unseal X25519 secret"));
    }
}
