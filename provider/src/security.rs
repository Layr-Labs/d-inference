//! Security hardening for the provider agent.
//!
//! This module implements runtime protections that prevent the provider
//! (machine owner) from inspecting inference data:
//!
//!   - PT_DENY_ATTACH: Prevents debugger attachment (lldb, dtrace)
//!   - SIP verification: Checks System Integrity Protection before each job
//!   - Memory wiping: Zeros sensitive buffers after use
//!
//! These protections work in conjunction with macOS Hardened Runtime (applied
//! at code signing time) and SIP to create a strong barrier against memory
//! inspection. With SIP enabled + Hardened Runtime + PT_DENY_ATTACH:
//!   - No debugger can attach to this process
//!   - No other process can read this process's memory
//!   - SIP cannot be disabled without rebooting (which kills the process)

use base64::Engine;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::process::Command;

/// Prevent debugger attachment using ptrace(PT_DENY_ATTACH).
///
/// On macOS, this syscall tells the kernel to deny any future ptrace
/// requests against this process. Even root cannot override this while
/// SIP is enabled. Combined with Hardened Runtime (no get-task-allow
/// entitlement), this makes the process's memory unreadable.
///
/// Must be called early in process startup, before any sensitive data
/// is loaded.
pub fn deny_debugger_attachment() {
    #[cfg(target_os = "macos")]
    {
        // PT_DENY_ATTACH = 31 on macOS
        const PT_DENY_ATTACH: libc::c_int = 31;
        let result =
            unsafe { libc::ptrace(PT_DENY_ATTACH, 0, std::ptr::null_mut::<libc::c_char>(), 0) };
        if result == 0 {
            tracing::info!("Anti-debug: PT_DENY_ATTACH enabled — debugger attachment blocked");
        } else {
            // This can fail if a debugger is already attached (e.g., during development)
            let err = std::io::Error::last_os_error();
            tracing::warn!("Anti-debug: PT_DENY_ATTACH failed (debugger attached?): {err}");
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        tracing::debug!("Anti-debug: PT_DENY_ATTACH not available on this platform");
    }
}

/// Check if System Integrity Protection (SIP) is enabled.
///
/// SIP is the foundation of our security model. With SIP enabled:
///   - Hardened Runtime protections are enforced by the kernel
///   - Unsigned kernel extensions cannot load
///   - /dev/mem does not exist on Apple Silicon
///   - Root cannot modify /System or attach to protected processes
///
/// SIP cannot be disabled at runtime — it requires rebooting into
/// Recovery Mode. So if this check passes, SIP will remain enabled
/// for the lifetime of this process.
pub fn check_sip_enabled() -> bool {
    #[cfg(target_os = "macos")]
    {
        match Command::new("/usr/bin/csrutil").arg("status").output() {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let enabled = stdout.contains("enabled");
                if enabled {
                    tracing::info!("SIP check: System Integrity Protection is enabled");
                } else {
                    tracing::error!(
                        "SIP check: System Integrity Protection is DISABLED — refusing to serve"
                    );
                }
                enabled
            }
            Err(e) => {
                tracing::error!("SIP check: failed to run csrutil: {e}");
                false
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        tracing::debug!("SIP check: not applicable on this platform");
        true
    }
}

/// Check if RDMA (Remote Direct Memory Access) is disabled.
///
/// RDMA over Thunderbolt 5 allows another Mac to directly read this
/// process's memory at 80 Gb/s, bypassing PT_DENY_ATTACH, Hardened
/// Runtime, and SIP entirely. RDMA is disabled by default; enabling
/// requires booting into Recovery OS and running `rdma_ctl enable`.
///
/// Returns true if RDMA is disabled (safe) or if rdma_ctl is not
/// available (older macOS without RDMA support).
pub fn check_rdma_disabled() -> bool {
    #[cfg(target_os = "macos")]
    {
        match Command::new("/usr/bin/rdma_ctl").arg("status").output() {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let disabled = stdout.trim() == "disabled";
                if disabled {
                    tracing::info!("RDMA check: RDMA is disabled (safe)");
                } else {
                    tracing::error!(
                        "RDMA check: RDMA is ENABLED — remote memory access possible, refusing to serve"
                    );
                }
                disabled
            }
            Err(e) => {
                // rdma_ctl not found means RDMA is not supported on this Mac
                // (pre-macOS 26.2 or hardware without Thunderbolt 5 RDMA support).
                tracing::debug!("RDMA check: rdma_ctl not available ({e}), assuming safe");
                true
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        tracing::debug!("RDMA check: not applicable on this platform");
        true
    }
}

/// Check if hypervisor memory isolation is active.
///
/// When active, inference memory is protected by Stage 2 page tables
/// and is invisible to RDMA. This allows providers to serve even when
/// RDMA is enabled (required for multi-node inference).
pub fn check_hypervisor_active() -> bool {
    crate::hypervisor::is_active()
}

/// Verify all security prerequisites before accepting inference work.
///
/// Returns Ok(()) if all checks pass, Err with reason if any fail.
/// This should be called:
///   1. At process startup (before connecting to coordinator)
///   2. Before each inference request (belt-and-suspenders with startup check)
pub fn verify_security_posture() -> Result<(), String> {
    if !check_sip_enabled() {
        return Err(
            "SIP is disabled — cannot safely serve inference requests.\n\n\
             To enable SIP:\n\
             1. Shut down your Mac completely\n\
             2. Press and hold the power button until \"Loading startup options\" appears\n\
             3. Select Options, then Continue\n\
             4. From the menu bar: Utilities → Terminal\n\
             5. Type: csrutil enable\n\
             6. Restart your Mac\n\n\
             Then retry: dginf-provider serve"
                .to_string(),
        );
    }

    if !check_rdma_disabled() {
        // RDMA is enabled — only acceptable if hypervisor is active.
        // The hypervisor's Stage 2 page tables make inference memory
        // invisible to RDMA, so RDMA + hypervisor is safe.
        if check_hypervisor_active() {
            tracing::info!(
                "RDMA is enabled but hypervisor memory isolation is active — \
                 inference memory is hardware-protected"
            );
        } else {
            return Err("RDMA is enabled without hypervisor memory isolation — \
                 remote memory access possible, refusing to serve.\n\n\
                 To disable RDMA:\n\
                 1. Open System Settings → Sharing\n\
                 2. Disable Remote Direct Memory Access\n\n\
                 Then retry: dginf-provider serve"
                .to_string());
        }
    }

    // Verify app bundle signature if running from a .app bundle.
    // Any file modification breaks the code signature → refuses to serve.
    verify_bundle_signature()?;

    Ok(())
}

/// Check if this Mac is enrolled in DGInf MDM.
///
/// Tries multiple detection methods since system-level profiles
/// require sudo to see via `profiles list`. This is the single
/// source of truth for MDM enrollment status — all commands
/// should call this instead of implementing their own check.
pub fn check_mdm_enrolled() -> bool {
    #[cfg(target_os = "macos")]
    {
        // Method 1: Check if the system profiles marker file exists.
        // This file is created when any configuration profile is installed
        // at the system level, even if `profiles list` can't show it without sudo.
        if std::path::Path::new("/var/db/ConfigurationProfiles/Settings/.profilesAreInstalled")
            .exists()
        {
            tracing::debug!("MDM check: profiles marker file exists");
            return true;
        }

        // Method 2: Try `profiles list` (works for user-level profiles)
        let check_profiles = |args: &[&str]| -> bool {
            Command::new("profiles")
                .args(args)
                .output()
                .map(|o| {
                    let combined = format!(
                        "{}{}",
                        String::from_utf8_lossy(&o.stdout),
                        String::from_utf8_lossy(&o.stderr)
                    )
                    .to_lowercase();
                    // Positive signals
                    let has_profile = combined.contains("micromdm")
                        || combined.contains("com.github.micromdm")
                        || combined.contains("dginf")
                        || combined.contains("attribute: profileidentifier");
                    // Negative signal
                    let no_profiles = combined.contains("no configuration profiles");
                    has_profile || (!no_profiles && combined.contains("profileidentifier"))
                })
                .unwrap_or(false)
        };

        if check_profiles(&["list"]) {
            tracing::debug!("MDM check: found via profiles list");
            return true;
        }
        if check_profiles(&["list", "-type", "enrollment"]) {
            tracing::debug!("MDM check: found via profiles list -type enrollment");
            return true;
        }

        // Method 3: Check if mdmclient shows enrollment
        if let Ok(output) = Command::new("/usr/libexec/mdmclient")
            .args(["QueryDeviceInformation"])
            .output()
        {
            let out = String::from_utf8_lossy(&output.stdout).to_lowercase();
            if out.contains("enrolled") || out.contains("serverurl") {
                tracing::debug!("MDM check: found via mdmclient");
                return true;
            }
        }

        false
    }

    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Zero out a byte buffer to prevent sensitive data from persisting in memory.
///
/// Uses volatile writes to prevent the compiler from optimizing away
/// the zeroing operation (dead store elimination).
pub fn secure_zero(buf: &mut [u8]) {
    // Use write_volatile to prevent compiler from optimizing this away.
    // The compiler might otherwise remove the zeroing if the buffer
    // isn't read after being zeroed (dead store elimination).
    for byte in buf.iter_mut() {
        unsafe {
            std::ptr::write_volatile(byte, 0);
        }
    }
    // Fence to ensure the writes are committed before we return.
    std::sync::atomic::fence(std::sync::atomic::Ordering::SeqCst);
}

/// Zero out a String's backing buffer and then drop it.
pub fn secure_zero_string(mut s: String) {
    // SAFETY: We're zeroing the string's buffer in-place before dropping.
    // This is safe because we own the String and are about to drop it.
    unsafe {
        let bytes = s.as_bytes_mut();
        secure_zero(bytes);
    }
    drop(s);
}

/// Compute the SHA-256 hash of the currently running binary.
///
/// This hash is included in the attestation blob so the coordinator can
/// verify the provider is running the expected (blessed) version. A modified
/// binary produces a different hash and is rejected.
pub fn self_binary_hash() -> Option<String> {
    let exe_path = std::env::current_exe().ok()?;
    let hash = hash_file(&exe_path)?;
    tracing::info!("Binary self-hash ({}): {}", exe_path.display(), &hash[..16]);
    Some(hash)
}

/// Compute the SHA-256 hash of a file at the given path using streaming reads.
///
/// Reads in 64KB chunks to avoid loading entire files into memory.
/// Used for binary integrity verification and model weight fingerprinting.
pub fn hash_file(path: &std::path::Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = file.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(format!("{:x}", hasher.finalize()))
}

/// Compute a deterministic SHA-256 fingerprint over multiple files.
///
/// Files are sorted by name and streamed sequentially into a single hasher.
/// This produces a consistent hash regardless of filesystem ordering, suitable
/// for verifying sharded model weights (e.g. model-00001.safetensors, model-00002.safetensors).
pub fn hash_files_sorted(paths: &[std::path::PathBuf]) -> Option<String> {
    let mut sorted = paths.to_vec();
    sorted.sort();

    let mut hasher = Sha256::new();
    let mut buf = [0u8; 65536];
    for path in &sorted {
        let mut file = std::fs::File::open(path).ok()?;
        loop {
            let n = file.read(&mut buf).ok()?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
    }
    Some(format!("{:x}", hasher.finalize()))
}

/// Verify the integrity of the backend binary by checking its hash.
///
/// Returns Ok(hash) if the binary exists and can be hashed.
/// The coordinator can compare this against known-good hashes.
/// Returns Err if the binary is not found.
pub fn verify_backend_integrity(binary_name: &str) -> Result<String, String> {
    // Find the binary on PATH
    let output = Command::new("which")
        .arg(binary_name)
        .output()
        .map_err(|e| format!("failed to locate {binary_name}: {e}"))?;

    if !output.status.success() {
        return Err(format!("{binary_name} not found on PATH"));
    }

    let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let path = std::path::Path::new(&path_str);

    match hash_file(path) {
        Some(hash) => {
            tracing::info!(
                "Backend integrity: {} hash = {}...{}",
                binary_name,
                &hash[..8.min(hash.len())],
                &hash[hash.len().saturating_sub(8)..]
            );
            Ok(hash)
        }
        None => Err(format!("failed to hash {binary_name} at {path_str}")),
    }
}

/// Generate a unique Unix socket path for backend communication.
///
/// Uses a path in /tmp with restrictive permissions. Unix sockets
/// cannot be sniffed by tcpdump (unlike TCP localhost).
pub fn backend_socket_path() -> std::path::PathBuf {
    let pid = std::process::id();
    std::path::PathBuf::from(format!("/tmp/dginf-backend-{pid}.sock"))
}

/// Clean up the Unix socket file if it exists.
pub fn cleanup_socket(path: &std::path::Path) {
    if path.exists() {
        if let Err(e) = std::fs::remove_file(path) {
            tracing::warn!("Failed to clean up socket {}: {e}", path.display());
        }
    }
}

/// Verify the app bundle's code signature using macOS codesign.
///
/// If the binary is running from within a .app bundle, verify the
/// bundle's code signature is valid. A modified bundle (any file changed)
/// will fail this check.
///
/// Returns Ok(()) if the signature is valid or we're not in a bundle.
/// Returns Err if the signature is invalid (tampered bundle).
pub fn verify_bundle_signature() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find exe: {e}"))?;

    // Walk up to find the .app bundle
    let mut path = exe.as_path();
    let mut app_path = None;
    while let Some(parent) = path.parent() {
        if path.extension().and_then(|e| e.to_str()) == Some("app") {
            app_path = Some(path.to_path_buf());
            break;
        }
        path = parent;
    }

    let app_path = match app_path {
        Some(p) => p,
        None => {
            tracing::debug!("Not running from .app bundle, skipping bundle signature check");
            return Ok(());
        }
    };

    tracing::info!("Verifying app bundle signature: {}", app_path.display());

    match Command::new("/usr/bin/codesign")
        .args(["--verify", "--verbose=0", &app_path.to_string_lossy()])
        .output()
    {
        Ok(output) => {
            if output.status.success() {
                tracing::info!("App bundle signature valid");
                Ok(())
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                Err(format!("App bundle signature INVALID: {stderr}"))
            }
        }
        Err(e) => {
            tracing::warn!("Could not verify bundle signature: {e}");
            Ok(()) // Don't fail if codesign isn't available (non-macOS)
        }
    }
}

/// Compute SHA-256 of a byte slice, returning the hex digest.
pub fn sha256_bytes(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_secure_zero() {
        let mut buf = vec![0xAA_u8; 64];
        assert!(buf.iter().all(|&b| b == 0xAA));

        secure_zero(&mut buf);
        assert!(buf.iter().all(|&b| b == 0), "buffer should be zeroed");
    }

    #[test]
    fn test_secure_zero_empty() {
        let mut buf: Vec<u8> = vec![];
        secure_zero(&mut buf); // should not panic
    }

    #[test]
    fn test_secure_zero_string_fn() {
        let s = String::from("sensitive prompt data that should be wiped");
        // Just verify it doesn't panic. We can't reliably verify the memory
        // is zeroed after drop since the allocator may reuse it.
        secure_zero_string(s);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_sip_check_runs() {
        // On development machines, SIP should be enabled.
        // This test just verifies the check doesn't crash.
        let result = check_sip_enabled();
        // We don't assert true because some dev machines may have SIP disabled.
        // Just verify it returns a bool without panicking.
        let _ = result;
    }

    #[test]
    fn test_verify_security_posture() {
        // Just verify it doesn't panic
        let _ = verify_security_posture();
    }
}

/// Sign data with the Secure Enclave key via dginf-enclave CLI.
/// Returns the base64-encoded DER ECDSA signature.
pub fn se_sign(data: &[u8]) -> Option<String> {
    use std::io::Write;

    let dginf_dir = dirs::home_dir()?.join(".dginf");
    let enclave_bin = dginf_dir.join("bin/dginf-enclave");

    if !enclave_bin.exists() {
        return None;
    }

    // Write data to a temp file (dginf-enclave reads from stdin)
    let data_b64 = base64::engine::general_purpose::STANDARD.encode(data);

    let output = Command::new(&enclave_bin)
        .args(["sign", "--data", &data_b64])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let sig = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if sig.is_empty() {
        return None;
    }

    Some(sig)
}

/// Compute SHA-256 hash of data, return as hex string.
pub fn sha256_hex(data: &[u8]) -> String {
    sha256_bytes(data)
}
