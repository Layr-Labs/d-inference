//! Minimal same-binary operator command surface.

use std::{ffi::OsString, sync::Arc};

use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    database::Database,
    ledger::{
        JobId, LedgerService, ReviewDisposition, ReviewResolutionRequest,
        review_resolution_operation,
    },
    recovery::RecoveryService,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OperatorCommand {
    Serve,
    Version,
    ConfigCheck,
    Recovery,
    InvariantScan,
    ReviewResolve {
        job_id: JobId,
        disposition: ReviewDisposition,
        reason: Arc<str>,
    },
}

impl OperatorCommand {
    pub fn from_env() -> Result<Self, OperatorCommandError> {
        Self::parse(std::env::args_os().skip(1))
    }

    pub fn parse(
        arguments: impl IntoIterator<Item = OsString>,
    ) -> Result<Self, OperatorCommandError> {
        let arguments = arguments
            .into_iter()
            .map(|argument| {
                argument
                    .into_string()
                    .map_err(|_| OperatorCommandError::NonUtf8Argument)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let Some(command) = arguments.first().map(String::as_str) else {
            return Ok(Self::Serve);
        };
        match command {
            "serve" if arguments.len() == 1 => Ok(Self::Serve),
            "version" if arguments.len() == 1 => Ok(Self::Version),
            "check-config" | "config-check" if arguments.len() == 1 => Ok(Self::ConfigCheck),
            "recovery" if arguments.len() == 1 => Ok(Self::Recovery),
            "invariant-scan" if arguments.len() == 1 => Ok(Self::InvariantScan),
            "review-resolve" => parse_review_resolution(&arguments[1..]),
            _ => Err(OperatorCommandError::Usage),
        }
    }

    pub async fn execute_one_shot(
        &self,
        database: Database,
    ) -> Result<Value, OperatorCommandError> {
        match self {
            Self::InvariantScan => {
                let report = RecoveryService::new(database).scan_invariants().await?;
                serde_json::to_value(report).map_err(OperatorCommandError::Json)
            }
            Self::ReviewResolve {
                job_id,
                disposition,
                reason,
            } => {
                let operation = review_resolution_operation(*job_id, *disposition, reason)?;
                let result = LedgerService::new(database)
                    .resolve_review(&ReviewResolutionRequest {
                        operation,
                        job_id: *job_id,
                        disposition: *disposition,
                        operator_reason: reason.clone(),
                    })
                    .await?;
                Ok(json!({
                    "disposition": match result.disposition {
                        crate::ledger::MutationDisposition::Applied => "applied",
                        crate::ledger::MutationDisposition::Replayed => "replayed",
                    },
                    "job_id": result.job_id.as_uuid(),
                    "state": result.state.as_str(),
                    "version": result.version.as_i64(),
                }))
            }
            Self::Serve | Self::Version | Self::ConfigCheck | Self::Recovery => {
                Err(OperatorCommandError::NotOneShot)
            }
        }
    }
}

fn parse_review_resolution(arguments: &[String]) -> Result<OperatorCommand, OperatorCommandError> {
    let mut job_id = None;
    let mut disposition = None;
    let mut reason = None;
    let mut index = 0;
    while index < arguments.len() {
        let flag = arguments[index].as_str();
        let value = arguments
            .get(index + 1)
            .ok_or(OperatorCommandError::Usage)?;
        match flag {
            "--job" if job_id.is_none() => {
                let parsed =
                    Uuid::parse_str(value).map_err(|_| OperatorCommandError::InvalidJob)?;
                job_id = Some(JobId::new(parsed).map_err(|_| OperatorCommandError::InvalidJob)?);
            }
            "--disposition" if disposition.is_none() => {
                disposition = Some(match value.as_str() {
                    "settle" => ReviewDisposition::Settle,
                    "release" => ReviewDisposition::Release,
                    _ => return Err(OperatorCommandError::InvalidDisposition),
                });
            }
            "--reason" if reason.is_none() => {
                if value.is_empty()
                    || value.trim() != value
                    || value.len() > 4_096
                    || value.chars().any(char::is_control)
                {
                    return Err(OperatorCommandError::InvalidReason);
                }
                reason = Some(Arc::from(value.as_str()));
            }
            _ => return Err(OperatorCommandError::Usage),
        }
        index += 2;
    }
    Ok(OperatorCommand::ReviewResolve {
        job_id: job_id.ok_or(OperatorCommandError::Usage)?,
        disposition: disposition.ok_or(OperatorCommandError::Usage)?,
        reason: reason.ok_or(OperatorCommandError::Usage)?,
    })
}

#[derive(Debug, Error)]
pub enum OperatorCommandError {
    #[error(
        "usage: coordinator [serve|version|check-config|config-check|recovery|invariant-scan|review-resolve --job UUID --disposition settle|release --reason TEXT]"
    )]
    Usage,
    #[error("operator command arguments must be UTF-8")]
    NonUtf8Argument,
    #[error("review job must be a non-nil UUID")]
    InvalidJob,
    #[error("review disposition must be settle or release")]
    InvalidDisposition,
    #[error("review reason must be 1..=4096 trimmed non-control bytes")]
    InvalidReason,
    #[error("command is not a one-shot database operator command")]
    NotOneShot,
    #[error(transparent)]
    Ledger(#[from] crate::ledger::LedgerError),
    #[error("serialize operator result: {0}")]
    Json(serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_deployment_preflight_commands_exactly() {
        assert_eq!(
            OperatorCommand::parse([OsString::from("version")]).expect("version"),
            OperatorCommand::Version
        );
        assert_eq!(
            OperatorCommand::parse([OsString::from("config-check")]).expect("config-check"),
            OperatorCommand::ConfigCheck
        );
        assert_eq!(
            OperatorCommand::parse([OsString::from("check-config")]).expect("check-config"),
            OperatorCommand::ConfigCheck
        );
        assert!(matches!(
            OperatorCommand::parse([OsString::from("config-check;id")]),
            Err(OperatorCommandError::Usage)
        ));
        assert!(matches!(
            OperatorCommand::parse([
                OsString::from("config-check"),
                OsString::from("--unexpected")
            ]),
            Err(OperatorCommandError::Usage)
        ));
    }

    #[test]
    fn review_resolution_requires_a_journal_reason() {
        let job = Uuid::new_v4().to_string();
        assert!(matches!(
            OperatorCommand::parse([
                OsString::from("review-resolve"),
                OsString::from("--job"),
                OsString::from(job),
                OsString::from("--disposition"),
                OsString::from("release"),
                OsString::from("--reason"),
                OsString::from(""),
            ]),
            Err(OperatorCommandError::InvalidReason)
        ));
    }
}
