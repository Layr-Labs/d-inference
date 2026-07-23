use crate::planner::Planner;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use std::convert::Infallible;
use std::fs;
use std::future::Future;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::net::UnixListener;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

mod handler;

use handler::handle;

#[derive(Clone)]
pub struct ServerConfig {
    pub socket_path: PathBuf,
    pub max_body_bytes: usize,
    pub header_read_timeout: Duration,
    pub body_read_timeout: Duration,
    pub request_timeout: Duration,
    pub max_connections: usize,
}

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("Unix socket path is unsafe")]
    UnsafeSocket,
    #[error("Unix socket operation failed")]
    Io(#[from] std::io::Error),
}

pub async fn run(
    config: ServerConfig,
    planner: Planner,
    shutdown: impl Future<Output = ()>,
) -> Result<(), ServerError> {
    planner.mark_starting();
    prepare_socket(&config.socket_path)?;
    let listener = UnixListener::bind(&config.socket_path)?;
    fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o600))?;
    let metadata = fs::symlink_metadata(&config.socket_path)?;
    let socket_guard = SocketGuard {
        path: config.socket_path.clone(),
        device: metadata.dev(),
        inode: metadata.ino(),
    };
    let config = Arc::new(config);
    let connection_permits = Arc::new(Semaphore::new(config.max_connections.max(1)));
    let mut connections = JoinSet::new();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let Ok(permit) = connection_permits.clone().try_acquire_owned() else {
                    drop(stream);
                    continue;
                };
                let planner = planner.clone();
                let config = config.clone();
                connections.spawn(async move {
                    let _permit = permit;
                    let io = TokioIo::new(stream);
                    let header_read_timeout = config.header_read_timeout;
                    let service = service_fn(move |request| {
                        let planner = planner.clone();
                        let config = config.clone();
                        async move {
                            let response = handle(
                                request,
                                planner,
                                config.max_body_bytes,
                                config.body_read_timeout,
                                config.request_timeout,
                            )
                            .await;
                            Ok::<_, Infallible>(response)
                        }
                    });
                    let mut builder = http1::Builder::new();
                    builder
                        .keep_alive(true)
                        .max_headers(32)
                        .timer(TokioTimer::new())
                        .header_read_timeout(header_read_timeout);
                    let _ = builder.serve_connection(io, service).await;
                });
            }
        }
    }

    drop(listener);
    let drain = async { while connections.join_next().await.is_some() {} };
    if tokio::time::timeout(Duration::from_secs(2), drain)
        .await
        .is_err()
    {
        connections.abort_all();
    }
    drop(socket_guard);
    Ok(())
}

fn prepare_socket(path: &Path) -> Result<(), ServerError> {
    let parent = path.parent().ok_or(ServerError::UnsafeSocket)?;
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.file_type().is_dir()
        || parent_metadata.file_type().is_symlink()
        || parent_metadata.permissions().mode() & 0o077 != 0
    {
        return Err(ServerError::UnsafeSocket);
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {
            if std::os::unix::net::UnixStream::connect(path).is_ok() {
                return Err(ServerError::UnsafeSocket);
            }
            fs::remove_file(path)?;
        }
        Ok(_) => return Err(ServerError::UnsafeSocket),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(ServerError::Io(error)),
    }
    Ok(())
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}
