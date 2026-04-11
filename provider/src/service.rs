//! launchd user agent management for the darkbloom.
//!
//! The provider only runs when the user explicitly starts it via
//! `darkbloom start` or the macOS app's "Go Online" toggle.
//! It does NOT auto-start on login or auto-restart after crashes.
//! The user is always in control of when their GPU is being used.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

const LABEL: &str = "io.darkbloom.provider";

fn plist_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

fn uid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::getuid() }
    }
    #[cfg(not(unix))]
    {
        501
    }
}

fn write_plist(
    binary_path: &Path,
    coordinator_url: &str,
    models: &[String],
    image_model: Option<&str>,
    image_model_path: Option<&str>,
    stt_model: Option<&str>,
    idle_timeout: Option<u64>,
) -> Result<()> {
    let launch_agents_dir = plist_path()
        .parent()
        .expect("plist has a parent dir")
        .to_path_buf();
    std::fs::create_dir_all(&launch_agents_dir)
        .context("Failed to create ~/Library/LaunchAgents")?;

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".darkbloom/provider.log");

    let binary = binary_path.display();
    let log = log_path.display();

    let mut args = vec![
        format!("        <string>{binary}</string>"),
        "        <string>serve</string>".to_string(),
        "        <string>--coordinator</string>".to_string(),
        format!("        <string>{coordinator_url}</string>"),
    ];
    for model in models {
        args.push("        <string>--model</string>".to_string());
        args.push(format!("        <string>{model}</string>"));
    }
    if let Some(im) = image_model {
        args.push("        <string>--image-model</string>".to_string());
        args.push(format!("        <string>{im}</string>"));
    }
    if let Some(imp) = image_model_path {
        args.push("        <string>--image-model-path</string>".to_string());
        args.push(format!("        <string>{imp}</string>"));
    }
    if let Some(mins) = idle_timeout {
        args.push("        <string>--idle-timeout</string>".to_string());
        args.push(format!("        <string>{mins}</string>"));
    }
    let args_xml = args.join("\n");

    // Build environment variables section for non-CLI models (STT)
    let mut env_vars = String::new();
    if let Some(stt) = stt_model {
        env_vars = format!(
            r#"
    <key>EnvironmentVariables</key>
    <dict>
        <key>EIGENINFERENCE_STT_MODEL</key>
        <string>{stt}</string>
        <key>EIGENINFERENCE_STT_MODEL_ID</key>
        <string>{stt}</string>
    </dict>
"#
        );
    }

    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>

    <key>ProgramArguments</key>
    <array>
{args_xml}
    </array>
{env_vars}
    <key>KeepAlive</key>
    <false/>

    <key>RunAtLoad</key>
    <false/>

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

fn load_service() -> Result<()> {
    let path = plist_path();
    let domain = format!("gui/{}", uid());

    let output = std::process::Command::new("launchctl")
        .args(["bootstrap", &domain, &path.to_string_lossy()])
        .output()
        .context("Failed to run launchctl bootstrap")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if !stderr.contains("37:") && !stderr.contains("already loaded") {
            anyhow::bail!("launchctl bootstrap failed: {}", stderr.trim());
        }
    }

    // With RunAtLoad=false, bootstrap registers the service but doesn't start it.
    // Kickstart actually launches the process.
    let target = format!("gui/{}/{}", uid(), LABEL);
    let _ = std::process::Command::new("launchctl")
        .args(["kickstart", &target])
        .output();

    Ok(())
}

fn unload_service() -> Result<()> {
    let target = format!("gui/{}/{}", uid(), LABEL);

    let output = std::process::Command::new("launchctl")
        .args(["bootout", &target])
        .output()
        .context("Failed to run launchctl bootout")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("3:") || stderr.contains("could not find service") {
            return Ok(());
        }
        anyhow::bail!("launchctl bootout failed: {}", stderr.trim());
    }
    Ok(())
}

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

pub fn is_installed() -> bool {
    plist_path().exists()
}

/// Start the provider as a launchd user agent.
///
/// Writes the plist with KeepAlive=false and RunAtLoad=false, then loads it.
/// The provider runs until explicitly stopped or the machine reboots.
/// It does NOT auto-restart on crash or auto-start on login.
pub fn install_and_start(
    coordinator_url: &str,
    models: &[String],
    image_model: Option<&str>,
    image_model_path: Option<&str>,
    stt_model: Option<&str>,
    idle_timeout: Option<u64>,
) -> Result<()> {
    let binary_path = std::env::current_exe().unwrap_or_else(|_| {
        dirs::home_dir()
            .unwrap_or_default()
            .join(".darkbloom/bin/darkbloom")
    });

    if is_loaded() {
        unload_service().context("Failed to unload existing service")?;
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    write_plist(
        &binary_path,
        coordinator_url,
        models,
        image_model,
        image_model_path,
        stt_model,
        idle_timeout,
    )?;
    load_service().context("Failed to load launchd service")?;

    Ok(())
}

/// Stop the provider by unloading the launchd agent.
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
