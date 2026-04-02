//! launchd user agent management for the dginf-provider.
//!
//! Installs the provider as a macOS launchd service with `KeepAlive: true`
//! so it auto-restarts after crashes. Uses the modern `launchctl bootstrap`/
//! `bootout` API (gui/<uid> domain).

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// launchd service label.
const LABEL: &str = "io.dginf.provider";

/// Path to the launchd plist: ~/Library/LaunchAgents/io.dginf.provider.plist
fn plist_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

/// Get the current user's UID.
fn uid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::getuid() }
    }
    #[cfg(not(unix))]
    {
        501 // fallback, should never be used
    }
}

/// Write the plist XML file with the given serve arguments.
fn write_plist(binary_path: &Path, coordinator_url: &str, model: &str) -> Result<()> {
    let launch_agents_dir = plist_path()
        .parent()
        .expect("plist has a parent dir")
        .to_path_buf();
    std::fs::create_dir_all(&launch_agents_dir)
        .context("Failed to create ~/Library/LaunchAgents")?;

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/provider.log");

    let binary = binary_path.display();
    let log = log_path.display();

    // Generate plist XML directly — no external dependencies needed.
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>serve</string>
        <string>--coordinator</string>
        <string>{coordinator_url}</string>
        <string>--model</string>
        <string>{model}</string>
        <string>--all-models</string>
    </array>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>{log}</string>

    <key>StandardErrorPath</key>
    <string>{log}</string>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>Nice</key>
    <integer>-5</integer>
</dict>
</plist>
"#
    );

    std::fs::write(plist_path(), plist).context("Failed to write launchd plist")?;
    Ok(())
}

/// Load the service via `launchctl bootstrap gui/<uid> <plist>`.
fn load_service() -> Result<()> {
    let path = plist_path();
    let domain = format!("gui/{}", uid());

    let output = std::process::Command::new("launchctl")
        .args(["bootstrap", &domain, &path.to_string_lossy()])
        .output()
        .context("Failed to run launchctl bootstrap")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Error 37 = "Operation already in progress" — service already loaded.
        // This is fine; we unload first so it shouldn't happen, but handle gracefully.
        if stderr.contains("37:") || stderr.contains("already loaded") {
            tracing::debug!("Service already loaded, continuing");
            return Ok(());
        }
        anyhow::bail!("launchctl bootstrap failed: {}", stderr.trim());
    }
    Ok(())
}

/// Unload the service via `launchctl bootout gui/<uid>/io.dginf.provider`.
fn unload_service() -> Result<()> {
    let target = format!("gui/{}/{}", uid(), LABEL);

    let output = std::process::Command::new("launchctl")
        .args(["bootout", &target])
        .output()
        .context("Failed to run launchctl bootout")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Error 3 = "No such process" — service not loaded. That's fine.
        if stderr.contains("3:") || stderr.contains("could not find service") {
            return Ok(());
        }
        anyhow::bail!("launchctl bootout failed: {}", stderr.trim());
    }
    Ok(())
}

/// Check if the service is currently loaded in launchd.
pub fn is_loaded() -> bool {
    let target = format!("gui/{}/{}", uid(), LABEL);
    std::process::Command::new("launchctl")
        .args(["print", &target])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Check if the service plist is installed.
pub fn is_installed() -> bool {
    plist_path().exists()
}

/// Install and start the provider as a launchd user agent.
///
/// Writes the plist and loads it into launchd. If the service is already
/// loaded, it is unloaded first (to pick up any config changes).
pub fn install_and_start(coordinator_url: &str, model: &str) -> Result<()> {
    let binary_path = std::env::current_exe().unwrap_or_else(|_| {
        dirs::home_dir()
            .unwrap_or_default()
            .join(".dginf/bin/dginf-provider")
    });

    // Unload first if already loaded (picks up plist changes)
    if is_loaded() {
        unload_service().context("Failed to unload existing service")?;
        // Small delay for launchd to clean up
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    write_plist(&binary_path, coordinator_url, model)?;
    load_service().context("Failed to load launchd service")?;

    Ok(())
}

/// Stop the provider by unloading the launchd agent.
///
/// After bootout, KeepAlive will NOT restart the process — the service
/// is fully removed from the launchd session. The plist file is kept
/// on disk so `start` can reload it.
pub fn stop() -> Result<()> {
    if is_loaded() {
        unload_service().context("Failed to unload launchd service")?;
    }
    Ok(())
}

/// Completely remove the service: unload + delete plist.
pub fn uninstall() -> Result<()> {
    stop()?;
    let path = plist_path();
    if path.exists() {
        std::fs::remove_file(&path).context("Failed to remove launchd plist")?;
    }
    Ok(())
}
