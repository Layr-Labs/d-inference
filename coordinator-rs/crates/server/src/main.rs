use darkbloom_coordinator_server::{
    app::{AppState, router},
    config::Config,
    database::Database,
    runtime, shutdown,
};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let config = Config::from_env()?;
    let database = Database::connect(
        &config.database_url,
        config.database_max_connections,
        config.database_acquire_timeout,
    )
    .await?;
    let listener = match tokio::net::TcpListener::bind(config.bind_address).await {
        Ok(listener) => listener,
        Err(error) => {
            if let Err(close_error) = database.close(config.shutdown_grace).await {
                tracing::error!(error = %close_error, "database pool close failed after bind error");
            }
            return Err(error.into());
        }
    };
    tracing::info!(address = %config.bind_address, "Rust coordinator listening");

    let serve_result = runtime::serve(
        listener,
        router(AppState::new(database.clone())),
        shutdown::signal(),
        config.shutdown_grace,
    )
    .await;
    let close_result = database.close(config.shutdown_grace).await;
    if let Err(error) = serve_result {
        if let Err(close_error) = close_result {
            tracing::error!(error = %close_error, "database pool close failed after server error");
        }
        return Err(error.into());
    }
    close_result?;
    tracing::info!("Rust coordinator stopped");
    Ok(())
}
