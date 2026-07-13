//! Network and persistence adapters for the Rust coordinator.

pub mod app;
pub mod catalog;
pub mod config;
pub mod crypto;
pub mod database;
pub mod db;
#[cfg(feature = "fault-injection")]
pub mod fault;
pub mod fleet;
pub mod http;
pub mod ledger;
mod mutation_fence;
pub mod operator;
pub mod ownership;
pub mod pilot;
pub mod projection;
pub mod provider;
pub mod provider_control;
pub mod recovery;
pub mod request;
pub mod runtime;
pub mod schema;
pub mod shutdown;
pub mod supervisor;
pub mod surface;
pub mod telemetry;
pub mod trust;

/// Awaits and maps an asynchronous compile-time fault checkpoint.
///
/// The complete block is removed when `fault-injection` is disabled.
#[macro_export]
macro_rules! fault_checkpoint_async {
    ($point:ident, $symbol:literal, |$error:ident| $map:expr) => {{
        #[cfg(feature = "fault-injection")]
        {
            if let Err($error) = $crate::fault::checkpoint_async(
                $crate::fault::FaultPoint::$point,
                file!(),
                module_path!(),
                line!(),
                $symbol,
            )
            .await
            {
                let _ = &$error;
                return Err($map);
            }
        }
    }};
}

/// Maps a synchronous compile-time fault checkpoint.
///
/// Synchronous hooks reject delay plans at arm time.
#[macro_export]
macro_rules! fault_checkpoint_sync {
    ($point:ident, $symbol:literal, |$error:ident| $map:expr) => {{
        #[cfg(feature = "fault-injection")]
        {
            if let Err($error) = $crate::fault::checkpoint_sync(
                $crate::fault::FaultPoint::$point,
                file!(),
                module_path!(),
                line!(),
                $symbol,
            ) {
                let _ = &$error;
                return Err($map);
            }
        }
    }};
}
