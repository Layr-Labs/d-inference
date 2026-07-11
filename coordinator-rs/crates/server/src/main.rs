use darkbloom_coordinator_server::{
    app::{AppState, router},
    config::Config,
    database::Database,
    ownership::{CoordinatorOwnership, OwnershipError},
    pilot::{PilotHandle, PilotRuntime},
    runtime, shutdown,
    supervisor::SupervisorStatus,
};
use std::future::pending;
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
    tracing::info!(
        public_schema_version = database.compatibility().public_version,
        rust_schema_version = database.compatibility().rust_version,
        "PostgreSQL schema compatibility verified"
    );
    let ownership = match CoordinatorOwnership::configure(
        &database,
        &config.database_url,
        config.ownership_enabled,
    )
    .await
    {
        Ok(ownership) => ownership,
        Err(error) => {
            if let Err(close_error) = database.close(config.shutdown_grace).await {
                tracing::error!(error = %close_error, "database pool close failed after ownership error");
            }
            return Err(error.into());
        }
    };
    if ownership.fence().context().epoch_active() {
        tracing::info!(
            ownership_epoch = ownership.epoch(),
            ownership_backend_pid = ownership.backend_pid(),
            "Rust coordinator ownership acquired"
        );
    } else {
        tracing::warn!(
            ownership_backend_pid = ownership.backend_pid(),
            "Rust coordinator legacy ownership acquired with epoch activation disabled"
        );
    }

    // Durable recovery belongs here when Rust-owned jobs are introduced. The
    // ownership lock and epoch must already be active before recovery or serve.
    let listener = match tokio::net::TcpListener::bind(config.bind_address).await {
        Ok(listener) => listener,
        Err(error) => {
            if let Err(close_error) = database.close(config.shutdown_grace).await {
                tracing::error!(error = %close_error, "database pool close failed after bind error");
            }
            if let Err(release_error) = ownership.release().await {
                tracing::error!(error = %release_error, "coordinator ownership release failed after bind error");
            }
            return Err(error.into());
        }
    };
    tracing::info!(address = %config.bind_address, "Rust coordinator listening");

    let (pilot_task, pilot_handle) = if config.pilot.enabled {
        let (pilot, handle) = match PilotRuntime::build(&config.pilot).await {
            Ok(value) => value,
            Err(error) => {
                if let Err(close_error) = database.close(config.shutdown_grace).await {
                    tracing::error!(error = %close_error, "database pool close failed after pilot startup error");
                }
                if let Err(release_error) = ownership.release().await {
                    tracing::error!(error = %release_error, "coordinator ownership release failed after pilot startup error");
                }
                return Err(error.into());
            }
        };
        let task = tokio::spawn(pilot.run());
        (Some(task), Some(handle))
    } else {
        (None, None)
    };
    let mut state = AppState::new(database.clone()).with_ownership(ownership.status());
    if let Some(handle) = pilot_handle.clone() {
        state = state.with_pilot(handle);
    }
    let shutdown_ownership = ownership.status();
    let shutdown_pilot = pilot_handle.clone();
    let monitor_pilot = pilot_handle.clone();
    let serve_result = runtime::serve(
        listener,
        router(state),
        async move {
            tokio::select! {
                () = shutdown::signal() => {}
                () = shutdown_ownership.wait_until_unhealthy() => {
                    tracing::error!("coordinator ownership lost; shutting down runtime");
                }
                () = wait_for_pilot_exit(monitor_pilot) => {
                    tracing::error!("pilot supervisor ended; shutting down HTTP runtime");
                }
            }
            if let Some(pilot) = shutdown_pilot {
                pilot.shutdown();
            }
        },
        config.shutdown_grace,
    )
    .await;
    if let Some(pilot) = &pilot_handle {
        pilot.shutdown();
    }
    let pilot_result = match pilot_task {
        Some(task) => match task.await {
            Ok(result) => result.map_err(|error| -> Box<dyn std::error::Error> { Box::new(error) }),
            Err(error) => Err(Box::new(error) as Box<dyn std::error::Error>),
        },
        None => Ok(()),
    };
    let ownership_lost = !ownership.status().is_healthy();
    let close_result = database.close(config.shutdown_grace).await;
    let release_result = ownership.release().await;
    if let Err(error) = serve_result {
        if let Err(close_error) = close_result {
            tracing::error!(error = %close_error, "database pool close failed after server error");
        }
        if let Err(release_error) = release_result {
            tracing::error!(error = %release_error, "coordinator ownership release failed after server error");
        }
        return Err(error.into());
    }
    if let Err(error) = pilot_result {
        if let Err(close_error) = close_result {
            tracing::error!(error = %close_error, "database pool close failed after pilot error");
        }
        if let Err(release_error) = release_result {
            tracing::error!(error = %release_error, "coordinator ownership release failed after pilot error");
        }
        return Err(error);
    }
    if ownership_lost {
        if let Err(close_error) = close_result {
            tracing::error!(error = %close_error, "database pool close failed after ownership loss");
        }
        if let Err(release_error) = release_result {
            tracing::error!(error = %release_error, "coordinator ownership connection ended after loss");
        }
        return Err(OwnershipError::Lost.into());
    }
    close_result?;
    release_result?;
    tracing::info!("Rust coordinator stopped");
    Ok(())
}

async fn wait_for_pilot_exit(pilot: Option<PilotHandle>) {
    let Some(mut pilot) = pilot else {
        pending::<()>().await;
        return;
    };
    loop {
        match pilot.readiness().status {
            SupervisorStatus::Fatal | SupervisorStatus::Stopped => return,
            SupervisorStatus::Starting | SupervisorStatus::Ready | SupervisorStatus::Stopping => {}
        }
        if pilot.changed().await.is_err() {
            return;
        }
    }
}
