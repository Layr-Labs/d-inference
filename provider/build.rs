// Emits coordinator URL defaults at compile time.
//
// CI passes DARKBLOOM_COORDINATOR_URL (e.g. https://api.darkbloom.dev) per
// environment; this script derives the WebSocket and enroll-profile forms and
// re-exports them as individual env vars that `option_env!` picks up in code.
//
// If DARKBLOOM_COORDINATOR_URL is not set, the env vars are not emitted and the
// source-level fallbacks (prod URLs) apply. Local dev builds therefore behave
// identically to today.

use std::env;

fn main() {
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
