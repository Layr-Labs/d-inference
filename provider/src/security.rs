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
pub fn deny_debugger_attachment() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        // PT_DENY_ATTACH = 31 on macOS
        const PT_DENY_ATTACH: libc::c_int = 31;
        let result =
            unsafe { libc::ptrace(PT_DENY_ATTACH, 0, std::ptr::null_mut::<libc::c_char>(), 0) };
        if result == 0 {
            tracing::info!("Anti-debug: PT_DENY_ATTACH enabled — debugger attachment blocked");
            return Ok(());
        } else {
            let err = std::io::Error::last_os_error();
            return Err(format!(
                "PT_DENY_ATTACH failed; refusing to continue without anti-debug protection: {err}"
            ));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        tracing::debug!("Anti-debug: PT_DENY_ATTACH not available on this platform");
        Ok(())
    }
}

/// Disable core dumps for this process.
///
/// Core dumps can contain plaintext prompts, model weights, and private keys.
/// Setting RLIMIT_CORE to zero prevents the kernel from writing core files
/// even if the process crashes. This complements PT_DENY_ATTACH and Hardened
/// Runtime to ensure no crash artifact leaks sensitive data.
pub fn disable_core_dumps() -> Result<(), String> {
    #[cfg(unix)]
    {
        let zero = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        let ret = unsafe { libc::setrlimit(libc::RLIMIT_CORE, &zero) };
        if ret == 0 {
            tracing::info!("Core dumps disabled (RLIMIT_CORE = 0)");
            Ok(())
        } else {
            let err = std::io::Error::last_os_error();
            Err(format!("failed to disable core dumps: {err}"))
        }
    }

    #[cfg(not(unix))]
    {
        tracing::debug!("Core dump disable not available on this platform");
        Ok(())
    }
}

/// Scrub environment variables that could leak into the Python runtime or
/// child processes. Called once at startup before any inference work.
pub fn scrub_private_env() {
    const DANGEROUS_VARS: &[&str] = &[
        "PYTHONPATH",
        "PYTHONSTARTUP",
        "PYTHONHOME",
        "PYTHONDONTWRITEBYTECODE",
        "PYTHONIOENCODING",
        "LD_PRELOAD",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
    ];

    for var in DANGEROUS_VARS {
        if std::env::var_os(var).is_some() {
            tracing::warn!("Scrubbing dangerous env var: {var}");
            unsafe {
                std::env::remove_var(var);
            }
        }
    }
}

/// Isolate the Python interpreter BEFORE it initializes.
///
/// Must be called before any PyO3 `Python::with_gil` call. Sets env vars that
/// CPython reads during `Py_Initialize` to prevent `sitecustomize.py` and
/// `usercustomize.py` from running. Without this, a malicious
/// `sitecustomize.py` in system site-packages would execute before
/// `lock_python_path` takes effect.
pub fn isolate_python_preinit() {
    unsafe {
        std::env::set_var("PYTHONNOUSERSITE", "1");
        std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");
        // Do NOT set PYTHONISOLATED — it causes Python to ignore PYTHONHOME,
        // breaking the bundled runtime path. PYTHONNOUSERSITE is sufficient to
        // block user site-packages. The full import path lock (lock_python_path)
        // handles the rest after initialization.
    }
    tracing::info!("Python pre-init isolation: PYTHONNOUSERSITE=1, PYTHONDONTWRITEBYTECODE=1");
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
                    tracing::debug!("RDMA check: RDMA is disabled");
                } else {
                    tracing::debug!("RDMA check: RDMA is enabled");
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
             Then retry: darkbloom serve"
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
                 Then retry: darkbloom serve"
                .to_string());
        }
    }

    // Verify app bundle signature if running from a .app bundle.
    // Any file modification breaks the code signature → refuses to serve.
    verify_bundle_signature()?;

    Ok(())
}

/// Check if this Mac is enrolled in Darkbloom MDM.
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
                        || combined.contains("eigeninference")
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

/// Recursively zero any sensitive string contents held inside a JSON value,
/// then replace the container with `null`.
pub fn secure_zero_json_value(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::String(s) => {
            secure_zero_string(std::mem::take(s));
        }
        serde_json::Value::Array(items) => {
            for item in items.iter_mut() {
                secure_zero_json_value(item);
            }
            items.clear();
        }
        serde_json::Value::Object(map) => {
            for item in map.values_mut() {
                secure_zero_json_value(item);
            }
            map.clear();
        }
        _ => {}
    }
    *value = serde_json::Value::Null;
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
/// Each file is hashed independently on its own thread (parallel), then the
/// per-file hashes are combined in sorted filename order into a final hash.
/// This produces a consistent result regardless of filesystem ordering and
/// scales with the number of CPU cores for sharded model weights.
pub fn hash_files_sorted(paths: &[std::path::PathBuf]) -> Option<String> {
    let mut sorted = paths.to_vec();
    sorted.sort();

    // Hash each file in parallel on its own thread.
    let handles: Vec<_> = sorted
        .iter()
        .map(|path| {
            let path = path.clone();
            std::thread::spawn(move || -> Option<[u8; 32]> {
                let mut hasher = Sha256::new();
                let mut buf = [0u8; 65536];
                let mut file = std::fs::File::open(&path).ok()?;
                loop {
                    let n = file.read(&mut buf).ok()?;
                    if n == 0 {
                        break;
                    }
                    hasher.update(&buf[..n]);
                }
                Some(hasher.finalize().into())
            })
        })
        .collect();

    // Collect per-file hashes and combine in sorted order.
    let mut final_hasher = Sha256::new();
    for handle in handles {
        let file_hash = handle.join().ok()??;
        final_hasher.update(file_hash);
    }
    Some(format!("{:x}", final_hasher.finalize()))
}

/// Hashes of the Python runtime, vllm-mlx package, and templates.
///
/// Reported to the coordinator during registration and attestation
/// so it can verify the provider is running expected runtime code.
#[derive(Debug, Clone)]
pub struct RuntimeHashes {
    /// SHA-256 hash of the Python binary itself.
    pub python_hash: Option<String>,
    /// SHA-256 hash of the full allowed Python runtime tree under
    /// `lib/python3.12` (stdlib + lib-dynload + site-packages), combined in
    /// sorted order with `hash_files_sorted`.
    pub runtime_hash: Option<String>,
    /// Per-file SHA-256 hashes of Jinja templates in ~/.darkbloom/templates/.
    pub template_hashes: std::collections::HashMap<String, String>,
}

/// Recursively collect all files matching an extension under a directory.
///
/// Simple recursive walk using `std::fs::read_dir` — no external crate needed.
/// The vllm_mlx directory is shallow so this is efficient.
/// Delete all `__pycache__` directories and `.pyc` files under `dir`.
///
/// SECURITY: Python executes `.pyc` bytecode instead of `.py` source on import.
/// A malicious `.pyc` could intercept inference data without modifying any `.py`.
/// By purging before every hash check, we force Python to recompile from the
/// verified `.py` source and ensure the hash matches CI's clean state.
fn purge_pycache(dir: &std::path::Path) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().and_then(|n| n.to_str()) == Some("__pycache__") {
                let _ = std::fs::remove_dir_all(&path);
            } else {
                purge_pycache(&path);
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some("pyc") {
            let _ = std::fs::remove_file(&path);
        }
    }
}

fn collect_files_recursive(
    dir: &std::path::Path,
    extension: &str,
    out: &mut Vec<std::path::PathBuf>,
) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().and_then(|n| n.to_str()) == Some("__pycache__") {
                continue;
            }
            collect_files_recursive(&path, extension, out);
        } else if extension == "*" || path.extension().and_then(|e| e.to_str()) == Some(extension) {
            out.push(path);
        }
    }
}

fn runtime_lib_dir_from_python_cmd(python_cmd: &str) -> Option<std::path::PathBuf> {
    let python_path = std::path::Path::new(python_cmd);
    let from_python_bin = python_path
        .parent()
        .and_then(|bin| bin.parent())
        .map(|root| root.join("lib").join("python3.12"));
    if let Some(lib_dir) = from_python_bin.filter(|path| path.exists()) {
        return Some(lib_dir);
    }

    dirs::home_dir().map(|home| home.join(".darkbloom/python/lib/python3.12"))
}

/// Compute hashes of the Python runtime, all packages, and templates.
///
/// These hashes allow the coordinator to verify that the provider is running
/// the expected (blessed) runtime code — not a modified version that could
/// leak prompts or produce tampered output.
///
/// - `python_hash`: SHA-256 of the Python interpreter binary
/// - `runtime_hash`: Combined SHA-256 of ALL files under `lib/python3.12`
///   (sorted, after purging `__pycache__` / `.pyc`). This covers stdlib,
///   `lib-dynload`, `site-packages`, and any other code reachable via the
///   locked private-text import path.
/// - `template_hashes`: Per-file SHA-256 of each .jinja template
pub fn compute_runtime_hashes(python_cmd: &str) -> RuntimeHashes {
    // Hash the Python binary itself
    let python_hash = hash_file(std::path::Path::new(python_cmd));

    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
    let runtime_hash = runtime_lib_dir_from_python_cmd(python_cmd)
        .filter(|lib_dir| lib_dir.exists())
        .and_then(|lib_dir| {
            purge_pycache(&lib_dir);
            let mut runtime_files = Vec::new();
            collect_files_recursive(&lib_dir, "*", &mut runtime_files);
            runtime_files
                .retain(|path| path.extension().and_then(|ext| ext.to_str()) != Some("pyc"));
            // Sort by string representation to match Python's str sort order.
            // PathBuf::cmp uses OS-specific ordering which can differ from
            // Python's os.path lexicographic sort on certain characters.
            runtime_files.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));
            if runtime_files.is_empty() {
                None
            } else {
                hash_files_sorted(&runtime_files)
            }
        });

    // Hash templates in ~/.darkbloom/templates/
    let templates_dir = eigeninference_dir.join("templates");
    let mut template_hashes = std::collections::HashMap::new();
    if templates_dir.exists() {
        for entry in std::fs::read_dir(&templates_dir).ok().into_iter().flatten() {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("jinja") {
                    if let Some(hash) = hash_file(&path) {
                        let name = path
                            .file_stem()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_string();
                        template_hashes.insert(name, hash);
                    }
                }
            }
        }
    }

    RuntimeHashes {
        python_hash,
        runtime_hash,
        template_hashes,
    }
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
    std::path::PathBuf::from(format!("/tmp/eigeninference-backend-{pid}.sock"))
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
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

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

    #[test]
    fn test_secure_zero_json_value_clears_nested_strings() {
        let mut value = serde_json::json!({
            "messages": [
                {"role": "user", "content": "secret prompt"},
                {"role": "assistant", "content": "secret reply"}
            ],
            "metadata": {"note": "sensitive"},
        });

        secure_zero_json_value(&mut value);
        assert_eq!(value, serde_json::Value::Null);
    }

    #[test]
    fn test_disable_core_dumps() {
        assert!(
            disable_core_dumps().is_ok(),
            "disable_core_dumps should succeed"
        );
    }

    #[test]
    fn test_scrub_private_env() {
        unsafe {
            std::env::set_var("PYTHONPATH", "/tmp/evil");
            std::env::set_var("DYLD_INSERT_LIBRARIES", "/tmp/evil.dylib");
        }
        scrub_private_env();
        assert!(
            std::env::var_os("PYTHONPATH").is_none(),
            "PYTHONPATH should be scrubbed"
        );
        assert!(
            std::env::var_os("DYLD_INSERT_LIBRARIES").is_none(),
            "DYLD_INSERT_LIBRARIES should be scrubbed"
        );
    }

    #[test]
    fn test_isolate_python_preinit() {
        unsafe {
            std::env::remove_var("PYTHONNOUSERSITE");
            std::env::remove_var("PYTHONISOLATED");
        }
        isolate_python_preinit();
        assert_eq!(
            std::env::var("PYTHONNOUSERSITE").unwrap(),
            "1",
            "PYTHONNOUSERSITE should be set"
        );
        assert!(
            std::env::var_os("PYTHONISOLATED").is_none(),
            "PYTHONISOLATED must not be set — it makes Python ignore PYTHONHOME"
        );
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

    #[test]
    fn test_collect_files_recursive() {
        let tmp = std::env::temp_dir().join("eigeninference_test_collect");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("sub")).unwrap();
        std::fs::write(tmp.join("a.py"), "# a").unwrap();
        std::fs::write(tmp.join("b.txt"), "not python").unwrap();
        std::fs::write(tmp.join("sub/c.py"), "# c").unwrap();

        let mut files = Vec::new();
        collect_files_recursive(&tmp, "py", &mut files);
        files.sort();

        assert_eq!(files.len(), 2, "should find 2 .py files");
        assert!(files[0].ends_with("a.py"));
        assert!(files[1].ends_with("c.py"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_collect_files_recursive_wildcard() {
        let tmp = std::env::temp_dir().join("eigeninference_test_collect_wildcard");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("sub")).unwrap();
        std::fs::write(tmp.join("a.py"), "# python").unwrap();
        std::fs::write(tmp.join("b.so"), "binary").unwrap();
        std::fs::write(tmp.join("c.json"), "{}").unwrap();
        std::fs::write(tmp.join("sub/d.dylib"), "lib").unwrap();
        std::fs::write(tmp.join("sub/e.txt"), "text").unwrap();

        let mut files = Vec::new();
        collect_files_recursive(&tmp, "*", &mut files);
        files.sort();

        assert_eq!(files.len(), 5, "wildcard should find all 5 files");

        // Verify it finds all extensions
        let extensions: Vec<_> = files
            .iter()
            .filter_map(|p| p.extension().and_then(|e| e.to_str()).map(String::from))
            .collect();
        assert!(extensions.contains(&"py".to_string()));
        assert!(extensions.contains(&"so".to_string()));
        assert!(extensions.contains(&"json".to_string()));
        assert!(extensions.contains(&"dylib".to_string()));
        assert!(extensions.contains(&"txt".to_string()));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_collect_files_recursive_wildcard_vs_filtered() {
        let tmp = std::env::temp_dir().join("eigeninference_test_wildcard_vs_filter");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("code.py"), "# python").unwrap();
        std::fs::write(tmp.join("ext.so"), "binary").unwrap();
        std::fs::write(tmp.join("data.json"), "{}").unwrap();

        let mut py_only = Vec::new();
        collect_files_recursive(&tmp, "py", &mut py_only);
        assert_eq!(py_only.len(), 1, "py filter should find 1 file");

        let mut all = Vec::new();
        collect_files_recursive(&tmp, "*", &mut all);
        assert_eq!(all.len(), 3, "wildcard should find all 3 files");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_hash_files_sorted_deterministic_with_mixed_types() {
        let tmp = std::env::temp_dir().join("eigeninference_test_hash_mixed");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("a.py"), "python code").unwrap();
        std::fs::write(tmp.join("b.so"), "compiled extension").unwrap();
        std::fs::write(tmp.join("c.json"), "{\"key\": \"value\"}").unwrap();

        let mut files = Vec::new();
        collect_files_recursive(&tmp, "*", &mut files);
        files.sort();

        let hash1 = hash_files_sorted(&files);
        let hash2 = hash_files_sorted(&files);
        assert!(hash1.is_some());
        assert_eq!(hash1, hash2, "hash should be deterministic");

        // Modify one file — hash should change
        std::fs::write(tmp.join("b.so"), "tampered extension").unwrap();
        let hash3 = hash_files_sorted(&files);
        assert_ne!(
            hash1, hash3,
            "hash should change when a .so file is modified"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_collect_files_recursive_nonexistent_dir() {
        let mut files = Vec::new();
        collect_files_recursive(std::path::Path::new("/nonexistent/path"), "py", &mut files);
        assert!(files.is_empty());
    }

    #[test]
    fn test_compute_runtime_hashes_nonexistent_python() {
        // With a non-existent Python binary, python_hash should be None
        let hashes = compute_runtime_hashes("/nonexistent/python3");
        assert!(hashes.python_hash.is_none());
        // runtime_hash and template_hashes depend on ~/.darkbloom presence,
        // but should never panic.
    }

    #[test]
    fn test_compute_runtime_hashes_with_temp_structure() {
        let _guard = env_lock().lock().unwrap();
        let tmp = std::env::temp_dir().join("eigeninference_test_runtime");
        let _ = std::fs::remove_dir_all(&tmp);

        // Create a mock directory structure
        let runtime_lib = tmp.join("python/lib/python3.12");
        let vllm_dir = runtime_lib.join("site-packages/vllm_mlx");
        std::fs::create_dir_all(&vllm_dir).unwrap();
        std::fs::write(vllm_dir.join("__init__.py"), "# init").unwrap();
        std::fs::write(vllm_dir.join("server.py"), "# server").unwrap();
        let dynload_dir = runtime_lib.join("lib-dynload");
        std::fs::create_dir_all(&dynload_dir).unwrap();
        std::fs::write(dynload_dir.join("_ssl.so"), "compiled ext").unwrap();
        std::fs::write(runtime_lib.join("json.py"), "# stdlib").unwrap();

        let templates_dir = tmp.join(".darkbloom/templates");
        std::fs::create_dir_all(&templates_dir).unwrap();
        std::fs::write(
            templates_dir.join("chatml.jinja"),
            "{% for m in messages %}",
        )
        .unwrap();
        std::fs::write(templates_dir.join("llama.jinja"), "{{ bos_token }}").unwrap();

        // Create a mock python binary
        let python_bin = tmp.join("python/bin/python3.12");
        std::fs::create_dir_all(python_bin.parent().unwrap()).unwrap();
        std::fs::write(&python_bin, "#!/usr/bin/env python3\n").unwrap();

        let old_home = std::env::var_os("HOME");
        // SAFETY: this test serializes HOME mutations with `env_lock()`.
        unsafe { std::env::set_var("HOME", &tmp) };
        let hashes = compute_runtime_hashes(python_bin.to_str().unwrap());
        if let Some(old_home) = old_home {
            // SAFETY: this test serializes HOME mutations with `env_lock()`.
            unsafe { std::env::set_var("HOME", old_home) };
        } else {
            // SAFETY: this test serializes HOME mutations with `env_lock()`.
            unsafe { std::env::remove_var("HOME") };
        }

        assert!(
            hashes.python_hash.is_some(),
            "should hash the mock python binary"
        );

        let mut runtime_files = Vec::new();
        collect_files_recursive(&runtime_lib, "*", &mut runtime_files);
        runtime_files.sort();
        let expected_runtime_hash = hash_files_sorted(&runtime_files);
        assert_eq!(hashes.runtime_hash, expected_runtime_hash);
        assert_eq!(
            hashes.template_hashes.get("chatml").map(String::as_str),
            hash_file(&templates_dir.join("chatml.jinja")).as_deref()
        );
        assert_eq!(
            hashes.template_hashes.get("llama").map(String::as_str),
            hash_file(&templates_dir.join("llama.jinja")).as_deref()
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_compute_response_attestation_changes_with_response_body() {
        let (hash_a, _) = compute_response_attestation(None, "req-1", 7, "alpha");
        let (hash_b, _) = compute_response_attestation(None, "req-1", 7, "beta");

        assert_ne!(
            hash_a, hash_b,
            "response attestation hash must change when the response body changes"
        );
    }
}

/// Sign data with the in-process Secure Enclave handle.
///
/// Returns the base64-encoded DER ECDSA signature, or None if no handle
/// is available (e.g. running on a platform without Secure Enclave).
pub fn se_sign(
    handle: Option<&crate::secure_enclave_key::SecureEnclaveHandle>,
    data: &[u8],
) -> Option<String> {
    handle.and_then(|h| h.sign(data).ok())
}

/// Compute SHA-256 hash of data, return as hex string.
pub fn sha256_hex(data: &[u8]) -> String {
    sha256_bytes(data)
}

pub fn compute_response_attestation(
    se_handle: Option<&crate::secure_enclave_key::SecureEnclaveHandle>,
    request_id: &str,
    completion_tokens: u64,
    response_body: &str,
) -> (String, Option<String>) {
    let sign_data = format!("{request_id}:{completion_tokens}:{response_body}");
    let response_hash = sha256_hex(sign_data.as_bytes());
    let se_signature = se_sign(se_handle, response_hash.as_bytes());
    (response_hash, se_signature)
}
