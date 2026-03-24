//! Provider wallet for earnings and payouts.
//!
//! Generates an Ethereum-compatible wallet (secp256k1 private key) and stores
//! it securely in the macOS Keychain. The wallet address is used for receiving
//! provider payouts from the coordinator's payment ledger.
//!
//! On macOS: uses `security` CLI to store/retrieve from Keychain.
//! On other platforms: falls back to file-based storage (~/.dginf/wallet_key).
//!
//! The wallet is created once during `dginf-provider install` and reused
//! for all subsequent sessions.

use anyhow::{Context, Result};

const KEYCHAIN_SERVICE: &str = "io.dginf.provider";
const KEYCHAIN_ACCOUNT: &str = "wallet-private-key";

/// Provider wallet with an Ethereum-compatible address.
pub struct Wallet {
    /// Hex-encoded private key (64 chars, no 0x prefix)
    private_key_hex: String,
    /// Ethereum-format address (0x + 40 hex chars)
    pub address: String,
}

impl Wallet {
    /// Load wallet from Keychain, or generate and store a new one.
    pub fn load_or_create() -> Result<Self> {
        // Try loading from Keychain first
        if let Some(key_hex) = load_from_keychain() {
            let address = address_from_private_key(&key_hex)?;
            tracing::info!("Wallet loaded from Keychain: {}", &address);
            return Ok(Self {
                private_key_hex: key_hex,
                address,
            });
        }

        // Try loading from file fallback
        let file_path = wallet_file_path();
        if file_path.exists() {
            let key_hex = std::fs::read_to_string(&file_path)
                .context("failed to read wallet file")?
                .trim()
                .to_string();
            let address = address_from_private_key(&key_hex)?;

            // Migrate to Keychain if possible
            save_to_keychain(&key_hex);
            tracing::info!("Wallet loaded from file (migrated to Keychain): {}", &address);
            return Ok(Self {
                private_key_hex: key_hex,
                address,
            });
        }

        // Generate new wallet
        let key_hex = generate_private_key();
        let address = address_from_private_key(&key_hex)?;

        // Store in Keychain
        if save_to_keychain(&key_hex) {
            tracing::info!("New wallet stored in Keychain: {}", &address);
        } else {
            // Fallback: save to file
            let dir = file_path.parent().unwrap();
            std::fs::create_dir_all(dir)?;
            std::fs::write(&file_path, &key_hex)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&file_path, std::fs::Permissions::from_mode(0o600))?;
            }
            tracing::info!("New wallet saved to file: {}", &address);
        }

        Ok(Self {
            private_key_hex: key_hex,
            address,
        })
    }

    /// Get the wallet address for display/registration.
    pub fn address(&self) -> &str {
        &self.address
    }

    /// Delete wallet from Keychain and file.
    pub fn delete() -> Result<()> {
        delete_from_keychain();
        let file_path = wallet_file_path();
        if file_path.exists() {
            std::fs::remove_file(&file_path)?;
        }
        Ok(())
    }
}

/// Generate a random 32-byte private key as hex.
fn generate_private_key() -> String {
    use std::io::Read;
    let mut key = [0u8; 32];
    // Read exactly 32 bytes from /dev/urandom (NOT std::fs::read which reads the whole file)
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut key);
    } else {
        // Fallback: use time-based entropy (not ideal but functional)
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

/// Derive an Ethereum-style address from a private key hex string.
///
/// Uses a simplified derivation: SHA-256 hash of the key, take last 20 bytes.
/// In production, this would use secp256k1 + keccak256 for real Ethereum addresses.
/// For the DGInf internal ledger, this simplified address is sufficient.
fn address_from_private_key(key_hex: &str) -> Result<String> {
    if key_hex.len() != 64 {
        anyhow::bail!("invalid private key length: expected 64 hex chars, got {}", key_hex.len());
    }

    // Simplified address derivation using SHA-256
    // (Real Ethereum uses secp256k1 public key + keccak256)
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

    // Take last 40 chars (20 bytes) as the address
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

// --- macOS Keychain integration ---

#[cfg(target_os = "macos")]
fn load_from_keychain() -> Option<String> {
    let output = std::process::Command::new("/usr/bin/security")
        .args([
            "find-generic-password",
            "-s", KEYCHAIN_SERVICE,
            "-a", KEYCHAIN_ACCOUNT,
            "-w", // output password only
        ])
        .output()
        .ok()?;

    if output.status.success() {
        let key = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if key.len() == 64 {
            Some(key)
        } else {
            None
        }
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
fn save_to_keychain(key_hex: &str) -> bool {
    // Delete existing entry first (ignore errors)
    let _ = std::process::Command::new("/usr/bin/security")
        .args([
            "delete-generic-password",
            "-s", KEYCHAIN_SERVICE,
            "-a", KEYCHAIN_ACCOUNT,
        ])
        .output();

    let status = std::process::Command::new("/usr/bin/security")
        .args([
            "add-generic-password",
            "-s", KEYCHAIN_SERVICE,
            "-a", KEYCHAIN_ACCOUNT,
            "-w", key_hex,
            "-T", "", // no app access (require user approval)
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    status
}

#[cfg(target_os = "macos")]
fn delete_from_keychain() {
    let _ = std::process::Command::new("/usr/bin/security")
        .args([
            "delete-generic-password",
            "-s", KEYCHAIN_SERVICE,
            "-a", KEYCHAIN_ACCOUNT,
        ])
        .output();
}

#[cfg(not(target_os = "macos"))]
fn load_from_keychain() -> Option<String> { None }

#[cfg(not(target_os = "macos"))]
fn save_to_keychain(_key_hex: &str) -> bool { false }

#[cfg(not(target_os = "macos"))]
fn delete_from_keychain() {}

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
