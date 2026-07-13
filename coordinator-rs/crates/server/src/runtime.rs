use std::{
    future::{Future, IntoFuture},
    net::SocketAddr,
    time::Duration,
};

use axum::Router;
use thiserror::Error;
use tokio::{net::TcpListener, sync::oneshot, time::timeout};

#[derive(Debug, Error)]
pub enum ServeError {
    #[error("HTTP server failed: {0}")]
    Server(#[source] std::io::Error),
    #[error("HTTP shutdown exceeded {0:?}")]
    ShutdownTimeout(Duration),
}

/// Serves the application and bounds graceful connection draining after the
/// shutdown signal completes.
pub async fn serve<F>(
    listener: TcpListener,
    app: Router,
    shutdown: F,
    shutdown_grace: Duration,
) -> Result<(), ServeError>
where
    F: Future<Output = ()> + Send,
{
    let (drain_tx, drain_rx) = oneshot::channel();
    let server = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        let _ = drain_rx.await;
    })
    .into_future();
    tokio::pin!(server);
    tokio::pin!(shutdown);

    tokio::select! {
        result = &mut server => result.map_err(ServeError::Server),
        () = &mut shutdown => {
            let _ = drain_tx.send(());
            timeout(shutdown_grace, &mut server)
                .await
                .map_err(|_| ServeError::ShutdownTimeout(shutdown_grace))?
                .map_err(ServeError::Server)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{future::pending, sync::Arc, time::Duration};

    use axum::{Router, http::StatusCode, routing::get};
    use tokio::{
        io::AsyncWriteExt,
        net::{TcpListener, TcpStream},
        sync::{Notify, oneshot},
    };

    use super::{ServeError, serve};

    #[tokio::test]
    async fn immediate_shutdown_completes_cleanly() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        serve(listener, Router::new(), async {}, Duration::from_secs(1))
            .await
            .expect("clean shutdown");
    }

    #[tokio::test]
    async fn active_request_cannot_exceed_shutdown_grace() {
        let started = Arc::new(Notify::new());
        let handler_started = started.clone();
        let app = Router::new().route(
            "/hang",
            get(move || {
                let handler_started = handler_started.clone();
                async move {
                    handler_started.notify_one();
                    pending::<StatusCode>().await
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("listener address");
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let server = tokio::spawn(serve(
            listener,
            app,
            async move {
                let _ = shutdown_rx.await;
            },
            Duration::from_millis(20),
        ));

        let mut connection = TcpStream::connect(address).await.expect("connect");
        connection
            .write_all(b"GET /hang HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .expect("write request");
        started.notified().await;
        shutdown_tx.send(()).expect("send shutdown");

        let error = server
            .await
            .expect("server task")
            .expect_err("hanging request must reach shutdown deadline");
        assert!(matches!(error, ServeError::ShutdownTimeout(_)));
    }
}
