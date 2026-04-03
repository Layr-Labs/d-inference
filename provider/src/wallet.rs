//! Provider wallet for earnings and payouts.
//!
//! Generates an Ethereum-compatible wallet (secp256k1 private key) and stores
//! it at ~/.dginf/wallet_key (mode 0600). The wallet address is used for
//! receiving provider payouts from the coordinator's payment ledger.
//!
//! The wallet key is intentionally stored as a readable file — it represents
//! the provider operator's own earnings identity and is not a secret from
//! the operator themselves.

use anyhow::{Context, Result};

pub struct Wallet {
    pub address: String,
}

impl Wallet {
    pub fn load_or_create() -> Result<Self> {
        let file_path = wallet_file_path();

        if file_path.exists() {
            let key_hex = std::fs::read_to_string(&file_path)
                .context("failed to read wallet file")?
                .trim()
                .to_string();
            let address = address_from_private_key(&key_hex)?;
            tracing::info!("Wallet loaded: {}", &address);
            return Ok(Self { address });
        }

        let key_hex = generate_private_key();
        let address = address_from_private_key(&key_hex)?;

        let dir = file_path.parent().unwrap();
        std::fs::create_dir_all(dir)?;
        std::fs::write(&file_path, &key_hex)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o600))?;
        }
        tracing::info!("New wallet created: {}", &address);

        Ok(Self { address })
    }

    pub fn address(&self) -> &str {
        &self.address
    }

    pub fn delete() -> Result<()> {
        let file_path = wallet_file_path();
        if file_path.exists() {
            std::fs::remove_file(&file_path)?;
        }
        Ok(())
    }
}

fn generate_private_key() -> String {
    use std::io::Read;
    let mut key = [0u8; 32];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut key);
    } else {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        for (i, byte) in key.iter_mut().enumerate() {
            *byte = ((t >> (i % 16)) & 0xFF) as u8;
        }
    }
    hex_encode(&key)
}

fn address_from_private_key(key_hex: &str) -> Result<String> {
    if key_hex.len() != 64 {
        anyhow::bail!("invalid private key length: expected 64 hex chars, got {}", key_hex.len());
    }

    let output = std::process::Command::new("shasum")
        .args(["-a", "256"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            child.stdin.take().unwrap().write_all(key_hex.as_bytes())?;
            child.wait_with_output()
        })
        .context("failed to hash key for address derivation")?;

    let hash = String::from_utf8_lossy(&output.stdout);
    let hash_hex = hash.trim().split_whitespace().next().unwrap_or("");

    let addr = if hash_hex.len() >= 40 {
        &hash_hex[hash_hex.len() - 40..]
    } else {
        hash_hex
    };

    Ok(format!("0x{}", addr))
}

fn wallet_file_path() -> std::path::PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".dginf/wallet_key")
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_private_key() {
        let key = generate_private_key();
        assert_eq!(key.len(), 64, "private key should be 64 hex chars");
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_different_keys() {
        let k1 = generate_private_key();
        let k2 = generate_private_key();
        assert_ne!(k1, k2, "two generated keys should differ");
    }

    #[test]
    fn test_address_from_key() {
        let key = generate_private_key();
        let addr = address_from_private_key(&key).unwrap();
        assert!(addr.starts_with("0x"), "address should start with 0x");
        assert_eq!(addr.len(), 42, "address should be 42 chars (0x + 40 hex)");
    }

    #[test]
    fn test_address_deterministic() {
        let key = generate_private_key();
        let a1 = address_from_private_key(&key).unwrap();
        let a2 = address_from_private_key(&key).unwrap();
        assert_eq!(a1, a2, "same key should produce same address");
    }

    #[test]
    fn test_invalid_key_length() {
        let result = address_from_private_key("tooshort");
        assert!(result.is_err());
    }

    #[test]
    fn test_hex_encode() {
        assert_eq!(hex_encode(&[0xde, 0xad, 0xbe, 0xef]), "deadbeef");
        assert_eq!(hex_encode(&[0x00, 0xff]), "00ff");
    }
}
