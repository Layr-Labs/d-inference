/// Waits for the first supported process termination signal.
pub async fn signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate =
            signal(SignalKind::terminate()).expect("install SIGTERM handler for graceful shutdown");
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                result.expect("install Ctrl-C handler for graceful shutdown");
            }
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .expect("install Ctrl-C handler for graceful shutdown");
    }
}
