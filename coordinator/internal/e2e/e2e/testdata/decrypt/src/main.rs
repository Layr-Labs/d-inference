/// Minimal NaCl Box decryptor for cross-language compatibility testing.
///
/// Usage: decrypt-test <ephemeral_public_key_b64> <ciphertext_b64> <provider_private_key_b64>
///
/// - ephemeral_public_key_b64: base64-encoded 32-byte X25519 public key (coordinator's ephemeral key)
/// - ciphertext_b64: base64-encoded (24-byte nonce || NaCl Box encrypted data)
/// - provider_private_key_b64: base64-encoded 32-byte X25519 private key
///
/// Prints decrypted plaintext to stdout. Exits with code 1 on any error.
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use crypto_box::aead::Aead;
use crypto_box::{PublicKey, SalsaBox, SecretKey};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!(
            "usage: {} <ephemeral_pub_b64> <ciphertext_b64> <provider_priv_b64>",
            args[0]
        );
        std::process::exit(1);
    }

    let eph_pub_bytes = STANDARD.decode(&args[1]).unwrap_or_else(|e| {
        eprintln!("failed to decode ephemeral public key: {e}");
        std::process::exit(1);
    });
    let ciphertext = STANDARD.decode(&args[2]).unwrap_or_else(|e| {
        eprintln!("failed to decode ciphertext: {e}");
        std::process::exit(1);
    });
    let priv_bytes = STANDARD.decode(&args[3]).unwrap_or_else(|e| {
        eprintln!("failed to decode provider private key: {e}");
        std::process::exit(1);
    });

    if eph_pub_bytes.len() != 32 {
        eprintln!(
            "ephemeral public key must be 32 bytes, got {}",
            eph_pub_bytes.len()
        );
        std::process::exit(1);
    }
    if priv_bytes.len() != 32 {
        eprintln!(
            "provider private key must be 32 bytes, got {}",
            priv_bytes.len()
        );
        std::process::exit(1);
    }
    if ciphertext.len() < 24 {
        eprintln!(
            "ciphertext too short: expected at least 24 bytes for nonce, got {}",
            ciphertext.len()
        );
        std::process::exit(1);
    }

    let eph_pub_arr: [u8; 32] = eph_pub_bytes.try_into().unwrap();
    let priv_arr: [u8; 32] = priv_bytes.try_into().unwrap();

    let eph_pub = PublicKey::from(eph_pub_arr);
    let secret = SecretKey::from(priv_arr);
    let salsa_box = SalsaBox::new(&eph_pub, &secret);

    let nonce_bytes: [u8; 24] = ciphertext[..24].try_into().unwrap();
    let nonce = nonce_bytes.into();

    let plaintext = salsa_box
        .decrypt(&nonce, &ciphertext[24..])
        .unwrap_or_else(|e| {
            eprintln!("decryption failed: {e}");
            std::process::exit(1);
        });

    print!("{}", String::from_utf8(plaintext).unwrap_or_else(|e| {
        eprintln!("plaintext is not valid UTF-8: {e}");
        std::process::exit(1);
    }));
}
