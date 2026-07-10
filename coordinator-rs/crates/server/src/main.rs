use darkbloom_coordinator_server::{
    app::{AppState, router},
    config::Config,
    database::Database,
    shutdown,
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
    let listener = tokio::net::TcpListener::bind(config.bind_address).await?;
    tracing::info!(address = %config.bind_address, "Rust coordinator listening");

    axum::serve(listener, router(AppState::new(database.clone())))
        .with_graceful_shutdown(shutdown::signal())
        .await?;
    database.close().await;
    tracing::info!("Rust coordinator stopped");
    Ok(())
}
