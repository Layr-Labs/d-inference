// Emits coordinator URL defaults at compile time.
//
// CI passes DARKBLOOM_COORDINATOR_URL (e.g. https://api.darkbloom.dev) per
// environment; this script derives the WebSocket and enroll-profile forms and
// re-exports them as individual env vars that `option_env!` picks up in code.
//
// If DARKBLOOM_COORDINATOR_URL is not set, the env vars are not emitted and the
// source-level fallbacks (prod URLs) apply. Local dev builds therefore behave
// identically to today.

use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        link_enclave_library();
    }

    println!("cargo:rerun-if-env-changed=DARKBLOOM_COORDINATOR_URL");
    println!("cargo:rerun-if-env-changed=DARKBLOOM_R2_CDN_URL");
    println!("cargo:rerun-if-env-changed=DARKBLOOM_R2_SITE_PACKAGES_CDN_URL");

    if let Ok(base) = env::var("DARKBLOOM_COORDINATOR_URL") {
        let base = base.trim_end_matches('/').to_string();

        let ws_base = if let Some(rest) = base.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = base.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            panic!("DARKBLOOM_COORDINATOR_URL must start with http:// or https://");
        };

        let ws_url = format!("{ws_base}/ws/provider");
        let enroll_url = format!("{base}/enroll.mobileconfig");
        let install_url = format!("{base}/install.sh");

        println!("cargo:rustc-env=DARKBLOOM_COORDINATOR_HTTP_URL={base}");
        println!("cargo:rustc-env=DARKBLOOM_COORDINATOR_WS_URL={ws_url}");
        println!("cargo:rustc-env=DARKBLOOM_ENROLL_PROFILE_URL={enroll_url}");
        println!("cargo:rustc-env=DARKBLOOM_INSTALL_URL={install_url}");
    }

    // R2 CDN URL baked in per environment. If DARKBLOOM_R2_CDN_URL is set and
    // DARKBLOOM_R2_SITE_PACKAGES_CDN_URL is not, default the site-packages CDN
    // to the same bucket (dev co-locates them; prod historically uses two).
    if let Ok(cdn) = env::var("DARKBLOOM_R2_CDN_URL") {
        let cdn = cdn.trim_end_matches('/').to_string();
        println!("cargo:rustc-env=DARKBLOOM_R2_CDN_URL={cdn}");
        if env::var("DARKBLOOM_R2_SITE_PACKAGES_CDN_URL").is_err() {
            println!("cargo:rustc-env=DARKBLOOM_R2_SITE_PACKAGES_CDN_URL={cdn}");
        }
    }
    if let Ok(spk) = env::var("DARKBLOOM_R2_SITE_PACKAGES_CDN_URL") {
        let spk = spk.trim_end_matches('/').to_string();
        println!("cargo:rustc-env=DARKBLOOM_R2_SITE_PACKAGES_CDN_URL={spk}");
    }
}

fn link_enclave_library() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR unset"));
    let enclave_dir = manifest_dir.join("../enclave");
    let enclave_sources = enclave_dir.join("Sources/DarkbloomEnclave");
    let enclave_header = enclave_dir.join("include/darkbloom_enclave.h");
    let enclave_package = enclave_dir.join("Package.swift");

    println!("cargo:rerun-if-changed={}", enclave_package.display());
    println!("cargo:rerun-if-changed={}", enclave_sources.display());
    println!("cargo:rerun-if-changed={}", enclave_header.display());

    let status = Command::new("swift")
        .args(["build", "-c", "release", "--product", "DarkbloomEnclave"])
        .current_dir(&enclave_dir)
        .status()
        .expect("failed to invoke swift build for DarkbloomEnclave");
    assert!(status.success(), "swift build failed for DarkbloomEnclave");

    let lib_dir = enclave_dir.join(".build/arm64-apple-macosx/release");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());

    let sdk_path = command_output("xcrun", &["--sdk", "macosx", "--show-sdk-path"]);
    println!("cargo:rustc-link-search=native={sdk_path}/usr/lib/swift");

    let swiftc_path = command_output("xcrun", &["--toolchain", "swift", "--find", "swiftc"]);
    let toolchain_swift_lib = PathBuf::from(swiftc_path)
        .parent()
        .expect("swiftc path missing parent")
        .parent()
        .expect("swift toolchain path missing parent")
        .join("lib/swift/macosx");
    println!(
        "cargo:rustc-link-search=native={}",
        toolchain_swift_lib.display()
    );

    println!("cargo:rustc-link-lib=static=DarkbloomEnclave");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Security");
    println!("cargo:rustc-link-lib=framework=CryptoKit");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
}

fn command_output(binary: &str, args: &[&str]) -> String {
    let output = Command::new(binary)
        .args(args)
        .output()
        .unwrap_or_else(|err| panic!("failed to run {binary}: {err}"));
    assert!(
        output.status.success(),
        "{binary} {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("command output was not utf-8")
        .trim()
        .to_string()
}
