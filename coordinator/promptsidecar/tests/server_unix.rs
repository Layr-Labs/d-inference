use promptsidecar::planner::Planner;
use promptsidecar::server::{self, ServerConfig};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

#[tokio::test]
async fn unix_socket_is_private_and_removed_on_shutdown() {
    let server = RunningServer::start(TestServerOptions::default()).await;

    assert_eq!(
        fs::symlink_metadata(&server.socket)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    server.shutdown().await;
}

#[tokio::test]
async fn persistent_connection_uses_a_fresh_header_deadline_per_request() {
    let server = RunningServer::start(TestServerOptions::default()).await;
    let mut stream = BufReader::new(UnixStream::connect(&server.socket).await.unwrap());

    write_request(&mut stream, b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n").await;
    let health = read_response(&mut stream).await;
    assert!(health.starts_with("HTTP/1.1 200"));
    assert!(health.contains(r#""status":"starting""#));
    assert!(health.contains(r#""ready":false"#));

    write_request(&mut stream, b"GET /ready HTTP/1.1\r\nHost: local\r\n\r\n").await;
    let readiness = read_response(&mut stream).await;
    assert!(readiness.starts_with("HTTP/1.1 503"));
    assert!(readiness.contains(r#""ready":false"#));

    write_request(
        &mut stream,
        b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 1\r\n\r\n{",
    )
    .await;
    let malformed = read_response(&mut stream).await;
    assert!(malformed.starts_with("HTTP/1.1 400"));
    assert!(malformed.contains("malformed_json"));

    // Each complete request arrives within the 80 ms header deadline, while
    // the persistent connection remains open for longer than one deadline.
    for _ in 0..3 {
        tokio::time::sleep(Duration::from_millis(30)).await;
        write_request(&mut stream, b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n").await;
        assert!(read_response(&mut stream).await.starts_with("HTTP/1.1 200"));
    }

    drop(stream);
    server.shutdown().await;
}

#[tokio::test]
async fn oversized_request_body_is_rejected_before_reading() {
    let server = RunningServer::start(TestServerOptions::default()).await;
    let stream = UnixStream::connect(&server.socket).await.unwrap();
    let mut stream = BufReader::new(stream);
    write_request(
        &mut stream,
        b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 65\r\n\r\n",
    )
    .await;

    let response = read_response(&mut stream).await;
    assert!(response.starts_with("HTTP/1.1 413"));
    assert!(response.contains("body_too_large"));

    drop(stream);
    server.shutdown().await;
}

#[tokio::test]
async fn connection_above_the_configured_limit_is_closed() {
    let server = RunningServer::start(TestServerOptions {
        max_connections: 1,
        ..TestServerOptions::default()
    })
    .await;

    // Completing a request proves this persistent connection owns the sole
    // permit, so no scheduler delay is needed before opening the next one.
    let held = UnixStream::connect(&server.socket).await.unwrap();
    let mut held = BufReader::new(held);
    write_request(&mut held, b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n").await;
    assert!(read_response(&mut held).await.starts_with("HTTP/1.1 200"));

    let mut rejected = UnixStream::connect(&server.socket).await.unwrap();
    let _ = rejected
        .write_all(b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n")
        .await;
    let mut byte = [0u8; 1];
    let read = tokio::time::timeout(
        Duration::from_millis(100),
        tokio::io::AsyncReadExt::read(&mut rejected, &mut byte),
    )
    .await;
    assert!(
        matches!(read, Ok(Ok(0)) | Ok(Err(_))),
        "connection above the configured limit was not closed"
    );

    drop(held);
    server.shutdown().await;
}

#[tokio::test]
async fn incomplete_headers_and_bodies_observe_their_read_deadlines() {
    let server = RunningServer::start(TestServerOptions::default()).await;

    let mut stalled = UnixStream::connect(&server.socket).await.unwrap();
    stalled
        .write_all(b"GET /health HTTP/1.1\r\nHost:")
        .await
        .unwrap();
    let mut byte = [0u8; 1];
    let stalled_read = tokio::time::timeout(
        Duration::from_millis(250),
        tokio::io::AsyncReadExt::read(&mut stalled, &mut byte),
    )
    .await;
    assert!(
        matches!(stalled_read, Ok(Ok(0)) | Ok(Err(_))),
        "partial request headers were not closed at the header deadline"
    );

    let body_stalled = UnixStream::connect(&server.socket).await.unwrap();
    let mut body_stalled = BufReader::new(body_stalled);
    write_request(
        &mut body_stalled,
        b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 10\r\n\r\n{}",
    )
    .await;
    let response =
        tokio::time::timeout(Duration::from_millis(250), read_response(&mut body_stalled))
            .await
            .expect("partial body did not reach the request deadline");
    assert!(response.starts_with("HTTP/1.1 408"));
    assert!(response.contains("body_deadline_exceeded"));

    drop(stalled);
    drop(body_stalled);
    server.shutdown().await;
}

struct TestServerOptions {
    max_body_bytes: usize,
    header_read_timeout: Duration,
    body_read_timeout: Duration,
    max_connections: usize,
}

impl Default for TestServerOptions {
    fn default() -> Self {
        Self {
            max_body_bytes: 64,
            header_read_timeout: Duration::from_millis(80),
            body_read_timeout: Duration::from_millis(100),
            max_connections: 2,
        }
    }
}

struct RunningServer {
    _temp: TempDir,
    socket: PathBuf,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<Result<(), server::ServerError>>,
}

impl RunningServer {
    async fn start(options: TestServerOptions) -> Self {
        let temp = TempDir::new().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = temp.path().join("prompt.sock");
        let artifacts = temp.path().join("artifacts");
        fs::create_dir(&artifacts).unwrap();
        let planner = Planner::new(fs::canonicalize(artifacts).unwrap(), 1, 1, 1024);
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(server::run(
            ServerConfig {
                socket_path: socket.clone(),
                max_body_bytes: options.max_body_bytes,
                header_read_timeout: options.header_read_timeout,
                body_read_timeout: options.body_read_timeout,
                request_timeout: Duration::from_millis(100),
                max_connections: options.max_connections,
            },
            planner,
            async move {
                let _ = shutdown_rx.await;
            },
        ));
        wait_for_socket(&socket).await;
        Self {
            _temp: temp,
            socket,
            shutdown,
            task,
        }
    }

    async fn shutdown(self) {
        self.shutdown.send(()).unwrap();
        self.task.await.unwrap().unwrap();
        assert!(!self.socket.exists());
    }
}

async fn wait_for_socket(path: &std::path::Path) {
    tokio::time::timeout(Duration::from_secs(1), async {
        while !path.exists() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("Unix socket did not become ready");
}

async fn write_request(stream: &mut BufReader<UnixStream>, request: &[u8]) {
    stream.get_mut().write_all(request).await.unwrap();
}

async fn read_response(stream: &mut BufReader<UnixStream>) -> String {
    let mut response = String::new();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        stream.read_line(&mut line).await.unwrap();
        assert!(!line.is_empty());
        if let Some(value) = line
            .to_ascii_lowercase()
            .strip_prefix("content-length:")
            .map(str::trim)
        {
            content_length = value.parse().unwrap();
        }
        response.push_str(&line);
        if line == "\r\n" {
            break;
        }
    }
    let mut body = vec![0; content_length];
    tokio::io::AsyncReadExt::read_exact(stream, &mut body)
        .await
        .unwrap();
    response.push_str(std::str::from_utf8(&body).unwrap());
    response
}
