use crate::api::{ErrorResponse, PlanRequest};
use crate::planner::{PlanError, Planner};
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::header::{CONTENT_LENGTH, CONTENT_TYPE};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
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

type ResponseBody = Full<Bytes>;

#[derive(Clone)]
pub struct ServerConfig {
    pub socket_path: PathBuf,
    pub max_body_bytes: usize,
    pub header_read_timeout: Duration,
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
                            let response = match tokio::time::timeout(
                                config.request_timeout,
                                handle(request, planner, config.max_body_bytes),
                            )
                            .await
                            {
                                Ok(response) => response,
                                Err(_) => error_response(
                                    StatusCode::GATEWAY_TIMEOUT,
                                    "deadline_exceeded",
                                    "prompt planning deadline exceeded",
                                ),
                            };
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

async fn handle(
    request: Request<Incoming>,
    planner: Planner,
    max_body_bytes: usize,
) -> Response<ResponseBody> {
    match (request.method(), request.uri().path()) {
        (&Method::GET, "/health") => json_response(StatusCode::OK, br#"{"status":"ok"}"#.to_vec()),
        (&Method::POST, "/v1/plan") => {
            if request
                .headers()
                .get(CONTENT_LENGTH)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<usize>().ok())
                .is_some_and(|length| length > max_body_bytes)
            {
                return error_response(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "body_too_large",
                    "request body exceeded its bound",
                );
            }
            let bytes = match collect_bounded(request.into_body(), max_body_bytes).await {
                Ok(bytes) => bytes,
                Err(CollectError::TooLarge) => {
                    return error_response(
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "body_too_large",
                        "request body exceeded its bound",
                    );
                }
                Err(CollectError::Read) => {
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "malformed_body",
                        "request body could not be read",
                    );
                }
            };
            let plan_request: PlanRequest = match serde_json::from_slice(&bytes) {
                Ok(request) => request,
                Err(_) => {
                    return error_response(
                        StatusCode::BAD_REQUEST,
                        "malformed_json",
                        "request body is not a valid plan request",
                    );
                }
            };
            match planner.plan(plan_request).await {
                Ok(plan) => match serde_json::to_vec(&plan) {
                    Ok(body) => json_response(StatusCode::OK, body),
                    Err(_) => error_response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "internal_error",
                        "prompt plan could not be encoded",
                    ),
                },
                Err(error) => plan_error_response(error),
            }
        }
        _ => error_response(StatusCode::NOT_FOUND, "not_found", "endpoint not found"),
    }
}

enum CollectError {
    TooLarge,
    Read,
}

async fn collect_bounded(
    mut body: Incoming,
    max_body_bytes: usize,
) -> Result<Vec<u8>, CollectError> {
    let mut output = Vec::with_capacity(max_body_bytes.min(64 * 1024));
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| CollectError::Read)?;
        let Ok(data) = frame.into_data() else {
            continue;
        };
        if output.len().saturating_add(data.len()) > max_body_bytes {
            return Err(CollectError::TooLarge);
        }
        output.extend_from_slice(&data);
    }
    Ok(output)
}

fn plan_error_response(error: PlanError) -> Response<ResponseBody> {
    match error {
        PlanError::AtCapacity => error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "at_capacity",
            "prompt planner is at capacity",
        ),
        PlanError::TooManyTokens => error_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            "prompt_too_large",
            "prompt token count exceeded its bound",
        ),
        PlanError::Contract => error_response(
            StatusCode::FAILED_DEPENDENCY,
            "contract_unavailable",
            "prompt contract is unavailable",
        ),
        PlanError::Worker => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "worker_failure",
            "prompt planner worker failed",
        ),
        PlanError::InvalidScope
        | PlanError::Endpoint
        | PlanError::Normalize
        | PlanError::Render(_)
        | PlanError::Tokenize
        | PlanError::BlockHash => error_response(
            StatusCode::UNPROCESSABLE_ENTITY,
            "planning_failed",
            "request could not be planned",
        ),
    }
}

fn error_response(
    status: StatusCode,
    code: &'static str,
    message: &'static str,
) -> Response<ResponseBody> {
    let body = serde_json::to_vec(&ErrorResponse::new(code, message)).unwrap_or_else(|_| {
        br#"{"error":{"code":"internal_error","message":"internal error"}}"#.to_vec()
    });
    json_response(status, body)
}

fn json_response(status: StatusCode, body: Vec<u8>) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json")
        .body(Full::new(Bytes::from(body)))
        .expect("valid static HTTP response")
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
