use promptsidecar::planner::Planner;
use promptsidecar::server::{self, ServerConfig};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::oneshot;

#[tokio::test]
async fn unix_server_is_private_persistent_and_bounded() {
    let temp = TempDir::new().unwrap();
    fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = temp.path().join("prompt.sock");
    let artifacts = temp.path().join("artifacts");
    fs::create_dir(&artifacts).unwrap();
    let planner = Planner::new(fs::canonicalize(artifacts).unwrap(), 1, 1, 1024);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(server::run(
        ServerConfig {
            socket_path: socket.clone(),
            max_body_bytes: 64,
            header_read_timeout: Duration::from_millis(80),
            request_timeout: Duration::from_millis(100),
            max_connections: 2,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));

    wait_for_socket(&socket).await;
    assert_eq!(
        fs::symlink_metadata(&socket).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let stream = UnixStream::connect(&socket).await.unwrap();
    let mut stream = BufReader::new(stream);
    stream
        .get_mut()
        .write_all(b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n")
        .await
        .unwrap();
    let first = read_response(&mut stream).await;
    assert!(first.starts_with("HTTP/1.1 200"));
    assert!(first.ends_with(r#"{"status":"ok"}"#));

    stream
        .get_mut()
        .write_all(b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 1\r\n\r\n{")
        .await
        .unwrap();
    let second = read_response(&mut stream).await;
    assert!(second.starts_with("HTTP/1.1 400"));
    assert!(second.contains("malformed_json"));

    // The header deadline is per request, not a total connection lifetime.
    // This persistent connection remains healthy for longer than one deadline
    // because each complete request arrives promptly.
    for _ in 0..3 {
        tokio::time::sleep(Duration::from_millis(30)).await;
        stream
            .get_mut()
            .write_all(b"GET /health HTTP/1.1\r\nHost: local\r\n\r\n")
            .await
            .unwrap();
        assert!(read_response(&mut stream).await.starts_with("HTTP/1.1 200"));
    }

    let mut oversized = UnixStream::connect(&socket).await.unwrap();
    oversized
        .write_all(b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 65\r\n\r\n")
        .await
        .unwrap();
    let mut oversized = BufReader::new(oversized);
    let response = read_response(&mut oversized).await;
    assert!(response.starts_with("HTTP/1.1 413"));
    assert!(response.contains("body_too_large"));
    drop(oversized);

    let held = UnixStream::connect(&socket).await.unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;
    let mut rejected = UnixStream::connect(&socket).await.unwrap();
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
    let mut stalled = UnixStream::connect(&socket).await.unwrap();
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

    let body_stalled = UnixStream::connect(&socket).await.unwrap();
    let mut body_stalled = BufReader::new(body_stalled);
    body_stalled
        .get_mut()
        .write_all(b"POST /v1/plan HTTP/1.1\r\nHost: local\r\nContent-Length: 10\r\n\r\n{}")
        .await
        .unwrap();
    let stalled_response =
        tokio::time::timeout(Duration::from_millis(250), read_response(&mut body_stalled))
            .await
            .expect("partial body did not reach the request deadline");
    assert!(stalled_response.starts_with("HTTP/1.1 504"));
    assert!(stalled_response.contains("deadline_exceeded"));

    drop(stream);
    shutdown_tx.send(()).unwrap();
    task.await.unwrap().unwrap();
    assert!(!socket.exists());
}

async fn wait_for_socket(path: &std::path::Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("Unix socket did not become ready");
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
