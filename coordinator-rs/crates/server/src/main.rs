use darkbloom_coordinator_server::{
    app::{AppState, router},
    config::Config,
    database::Database,
    operator::OperatorCommand,
    ownership::{CoordinatorOwnership, OwnershipError},
    pilot::{PilotHandle, PilotRuntime},
    provider_control::ProviderControlPlane,
    recovery::{RecoveryRuntime, RecoveryRuntimeConfig},
    runtime, shutdown,
    supervisor::SupervisorStatus,
    surface::{FullSurfaceState, billing::WithdrawalRecovery, operations::AdmissionGate},
    telemetry::datadog::{self, Metric, Observability, Tag, TagKey},
};
use std::{future::pending, time::Duration};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let observability = Observability::install()?;
    let result = run().await;
    observability.shutdown(Duration::from_secs(5)).await;
    result
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let command = OperatorCommand::from_env()?;
    if command == OperatorCommand::Version {
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({
                "binary": "rust",
                "version": option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
                "build_commit": option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
                "build_date": option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
            }))?
        );
        return Ok(());
    }
    let config = Config::from_env()?;
    #[cfg(feature = "pilot-load")]
    require_pilot_load_loopback(config.bind_address)?;
    if command == OperatorCommand::ConfigCheck {
        println!(
            "{}",
            serde_json::to_string(&serde_json::json!({
                "binary": "rust",
                "configuration_valid": true,
                "database_configured": true,
                "ownership_configured": config.ownership_enabled,
                "full_surface_configured": config.full_surface.enabled,
            }))?
        );
        return Ok(());
    }
    let database = Database::connect(
        &config.database_url,
        config.database_max_connections,
        config.database_acquire_timeout,
    )
    .await?;
    tracing::info!(
        public_schema_version = database.compatibility().public_version,
        rust_schema_version = database.compatibility().rust_version,
        migration_checksum_valid = database.compatibility().migration_checksum_valid,
        "PostgreSQL schema compatibility verified"
    );
    datadog::gauge(
        Metric::SchemaVersion,
        database.compatibility().public_version as f64,
        &[Tag::new(TagKey::Schema, "public")],
    );
    datadog::gauge(
        Metric::SchemaVersion,
        database.compatibility().rust_version as f64,
        &[Tag::new(TagKey::Schema, "rust")],
    );
    datadog::gauge(Metric::SchemaChecksumValid, 1.0, &[]);
    if command == OperatorCommand::StateCounts {
        let output = command.execute_one_shot(database.clone()).await;
        let close_result = database.close(config.shutdown_grace).await;
        let output = output?;
        close_result?;
        println!("{}", serde_json::to_string(&output)?);
        return Ok(());
    }
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
    datadog::gauge(Metric::OwnershipHealthy, 1.0, &[]);
    datadog::gauge(Metric::OwnershipEpoch, ownership.epoch() as f64, &[]);

    if matches!(
        command,
        OperatorCommand::InvariantScan | OperatorCommand::ReviewResolve { .. }
    ) {
        let output = command.execute_one_shot(database.clone()).await;
        let close_result = database.close(config.shutdown_grace).await;
        let release_result = ownership.release().await;
        let output = output?;
        close_result?;
        release_result?;
        println!("{}", serde_json::to_string(&output)?);
        return Ok(());
    }
    if command == OperatorCommand::Recovery {
        let cancellation = CancellationToken::new();
        let provider_control = config
            .pilot
            .mdm_control
            .clone()
            .map(|mdm| {
                Ok::<_, Box<dyn std::error::Error>>(ProviderControlPlane::new(
                    database.clone(),
                    config.pilot.configured_provider_identities()?,
                    mdm,
                )?)
            })
            .transpose()?;
        let withdrawal_recovery = config
            .full_surface
            .stripe
            .clone()
            .map(|settings| WithdrawalRecovery::new(database.clone(), settings))
            .transpose()?;
        let recovery =
            RecoveryRuntime::new(database.clone(), None, RecoveryRuntimeConfig::default())?
                .with_provider_control(provider_control)
                .with_withdrawal_recovery(withdrawal_recovery);
        let run = recovery.run(cancellation.clone());
        tokio::pin!(run);
        let mut ownership_lost = false;
        let recovery_ownership = ownership.status();
        let result = tokio::select! {
            result = &mut run => result,
            () = shutdown::signal() => {
                cancellation.cancel();
                run.await
            }
            () = recovery_ownership.wait_until_unhealthy() => {
                ownership_lost = true;
                datadog::gauge(Metric::OwnershipHealthy, 0.0, &[]);
                cancellation.cancel();
                run.await
            }
        };
        let close_result = database.close(config.shutdown_grace).await;
        let release_result = ownership.release().await;
        result?;
        if ownership_lost {
            return Err(OwnershipError::Lost.into());
        }
        close_result?;
        release_result?;
        return Ok(());
    }

    #[cfg(feature = "pilot-load")]
    seed_pilot_load_balance(&database).await?;

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

    let full_surface_admission = config.full_surface.enabled.then(AdmissionGate::default);
    let (pilot_task, pilot_handle) = if config.pilot.enabled {
        let built = match &full_surface_admission {
            Some(admission) => {
                PilotRuntime::build_durable_with_admission(
                    &config.pilot,
                    database.clone(),
                    ownership.status(),
                    admission.clone(),
                )
                .await
            }
            None => {
                PilotRuntime::build_durable(&config.pilot, database.clone(), ownership.status())
                    .await
            }
        };
        let (pilot, handle) = match built {
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
    let mut admission_gate = full_surface_admission.clone();
    let mut operations_state = None;
    let mut telemetry_service = None;
    let mut withdrawal_recovery = None;
    if config.full_surface.enabled {
        let handle = pilot_handle
            .clone()
            .ok_or("full surface requires inference runtime")?;
        let full_surface = match FullSurfaceState::build_with_admission(
            &config.full_surface,
            database.clone(),
            ownership.fence().context(),
            handle,
            full_surface_admission
                .clone()
                .expect("enabled full surface has an admission gate"),
        ) {
            Ok(full_surface) => full_surface,
            Err(error) => {
                if let Some(pilot) = &pilot_handle {
                    pilot.shutdown();
                }
                if let Some(task) = pilot_task {
                    let _ = task.await;
                }
                if let Err(close_error) = database.clone().close(config.shutdown_grace).await {
                    tracing::error!(error = %close_error, "database pool close failed after full-surface startup error");
                }
                if let Err(release_error) = ownership.release().await {
                    tracing::error!(error = %release_error, "coordinator ownership release failed after full-surface startup error");
                }
                return Err(error.into());
            }
        };
        admission_gate = Some(full_surface.operations.admission_gate());
        operations_state = Some(full_surface.operations.clone());
        telemetry_service = Some(full_surface.operations.telemetry_service());
        withdrawal_recovery = full_surface.billing.withdrawal_recovery();
        state = state.with_full_surface(full_surface);
    }
    let recovery_cancellation = CancellationToken::new();
    let recovery_runtime = RecoveryRuntime::new(
        database.clone(),
        pilot_handle.clone(),
        RecoveryRuntimeConfig::default(),
    )?
    .with_admission_gate(admission_gate)
    .with_operations_state(operations_state)
    .with_telemetry_service(telemetry_service)
    .with_withdrawal_recovery(withdrawal_recovery);
    let (recovery_status_tx, recovery_status_rx) = watch::channel(false);
    let recovery_task_cancellation = recovery_cancellation.clone();
    let recovery_task = tokio::spawn(async move {
        let result = recovery_runtime.run(recovery_task_cancellation).await;
        let _ = recovery_status_tx.send(true);
        result
    });
    let shutdown_ownership = ownership.status();
    let shutdown_pilot = pilot_handle.clone();
    let monitor_pilot = pilot_handle.clone();
    let shutdown_recovery = recovery_cancellation.clone();
    let serve_result = runtime::serve(
        listener,
        router(state),
        async move {
            tokio::select! {
                () = shutdown::signal() => {}
                () = shutdown_ownership.wait_until_unhealthy() => {
                    datadog::gauge(Metric::OwnershipHealthy, 0.0, &[]);
                    tracing::error!("coordinator ownership lost; shutting down runtime");
                }
                () = wait_for_pilot_exit(monitor_pilot) => {
                    tracing::error!("pilot supervisor ended; shutting down HTTP runtime");
                }
                () = wait_for_recovery_exit(recovery_status_rx) => {
                    tracing::error!("durable recovery supervisor ended; shutting down HTTP runtime");
                }
            }
            shutdown_recovery.cancel();
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
    recovery_cancellation.cancel();
    let recovery_result = match recovery_task.await {
        Ok(result) => result.map_err(|error| -> Box<dyn std::error::Error> { Box::new(error) }),
        Err(error) => Err(Box::new(error) as Box<dyn std::error::Error>),
    };
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
    if let Err(error) = recovery_result {
        if let Err(close_error) = close_result {
            tracing::error!(error = %close_error, "database pool close failed after recovery error");
        }
        if let Err(release_error) = release_result {
            tracing::error!(error = %release_error, "coordinator ownership release failed after recovery error");
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

async fn wait_for_recovery_exit(mut status: watch::Receiver<bool>) {
    loop {
        if *status.borrow() {
            return;
        }
        if status.changed().await.is_err() {
            return;
        }
    }
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

#[cfg(feature = "pilot-load")]
fn require_pilot_load_loopback(address: std::net::SocketAddr) -> Result<(), &'static str> {
    if address.ip().is_loopback() {
        Ok(())
    } else {
        Err("pilot-load coordinator bind address must be loopback")
    }
}

#[cfg(all(test, feature = "pilot-load"))]
mod pilot_load_bind_tests {
    use super::require_pilot_load_loopback;

    #[test]
    fn pilot_load_binary_rejects_non_loopback_bind_addresses() {
        assert!(require_pilot_load_loopback("127.0.0.1:18081".parse().expect("IPv4")).is_ok());
        assert!(require_pilot_load_loopback("[::1]:18081".parse().expect("IPv6")).is_ok());
        assert!(require_pilot_load_loopback("0.0.0.0:18081".parse().expect("wildcard")).is_err());
    }
}

#[cfg(feature = "pilot-load")]
async fn seed_pilot_load_balance(database: &Database) -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("EIGENINFERENCE_RUST_PILOT_LOAD_SEED_ENABLED").as_deref() != Ok("true") {
        return Ok(());
    }
    let account_id = std::env::var("EIGENINFERENCE_RUST_PILOT_FUNDING_ACCOUNT_ID")
        .map_err(|_| "pilot-load funding account is required")?;
    let amount = std::env::var("EIGENINFERENCE_RUST_PILOT_FUNDING_MICRO_USD")
        .map_err(|_| "pilot-load funding amount is required")?
        .parse::<i64>()
        .map_err(|_| "pilot-load funding amount must be an integer")?;
    database.seed_pilot_balance(&account_id, amount).await?;
    Ok(())
}
