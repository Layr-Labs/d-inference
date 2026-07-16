use anyhow::{Context, Result};
use clap::Parser;
use promptsidecar::planner::Planner;
use promptsidecar::server::{self, ServerConfig};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Parser)]
#[command(name = "promptsidecar")]
struct Args {
    #[arg(long)]
    socket: PathBuf,
    #[arg(long, default_value = "/data/prompt-contracts")]
    artifact_root: PathBuf,
    #[arg(long, default_value_t = 4_194_304)]
    max_body_bytes: usize,
    #[arg(long, default_value_t = 4)]
    max_concurrency: usize,
    #[arg(long, default_value_t = 64)]
    max_connections: usize,
    #[arg(long, default_value_t = 8)]
    max_loaded_contracts: usize,
    #[arg(long, default_value_t = 1_048_576)]
    max_tokens: usize,
    #[arg(long, default_value_t = 1_000)]
    request_timeout_ms: u64,
    #[arg(long, default_value_t = 1_000)]
    header_read_timeout_ms: u64,
    #[arg(long, default_value_t = 1_024)]
    memory_limit_mib: u64,
    #[arg(long)]
    parent_pid: Option<u32>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    apply_parent_death_signal(args.parent_pid)?;
    apply_memory_limit(args.memory_limit_mib)?;
    let planner = Planner::new(
        args.artifact_root,
        args.max_concurrency,
        args.max_loaded_contracts,
        args.max_tokens,
    );
    let config = ServerConfig {
        socket_path: args.socket,
        max_body_bytes: args.max_body_bytes,
        header_read_timeout: Duration::from_millis(args.header_read_timeout_ms),
        request_timeout: Duration::from_millis(args.request_timeout_ms),
        max_connections: args.max_connections,
    };
    server::run(config, planner, shutdown_signal())
        .await
        .context("prompt sidecar server terminated")
}

#[cfg(target_os = "linux")]
fn apply_parent_death_signal(expected_parent: Option<u32>) -> Result<()> {
    // SAFETY: prctl receives the documented integer-only PR_SET_PDEATHSIG arguments.
    if unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) } != 0 {
        return Err(std::io::Error::last_os_error()).context("setting parent-death signal");
    }
    // The parent can exit between exec and prctl. The supervisor passes its PID
    // so this check also works when the coordinator is legitimately container PID 1.
    if expected_parent.is_some_and(|expected| unsafe { libc::getppid() } as u32 != expected) {
        anyhow::bail!("prompt sidecar parent exited during startup");
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn apply_parent_death_signal(_expected_parent: Option<u32>) -> Result<()> {
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let terminate = signal(SignalKind::terminate());
        let interrupt = signal(SignalKind::interrupt());
        match (terminate, interrupt) {
            (Ok(mut terminate), Ok(mut interrupt)) => {
                tokio::select! {
                    _ = terminate.recv() => {},
                    _ = interrupt.recv() => {},
                }
            }
            _ => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn apply_memory_limit(limit_mib: u64) -> Result<()> {
    let bytes = limit_mib
        .checked_mul(1024 * 1024)
        .context("memory limit overflow")?;
    let limit = libc::rlimit {
        rlim_cur: bytes as libc::rlim_t,
        rlim_max: bytes as libc::rlim_t,
    };
    // SAFETY: setrlimit reads a valid rlimit value and does not retain the pointer.
    let result = unsafe { libc::setrlimit(libc::RLIMIT_AS, &limit) };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).context("setting process memory limit");
    }
    Ok(())
}

// Darwin rejects both RLIMIT_AS and RLIMIT_RSS with EINVAL. Local macOS runs
// remain bounded by body, token, connection, concurrency, and loaded-contract
// limits; the production Linux sidecar additionally enforces RLIMIT_AS.
#[cfg(not(target_os = "linux"))]
fn apply_memory_limit(_limit_mib: u64) -> Result<()> {
    Ok(())
}
