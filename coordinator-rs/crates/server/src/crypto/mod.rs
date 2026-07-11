//! Cryptographic process identity, sealing, and durable replay support.

mod durable_io;
pub(crate) mod epoch_store;
pub use durable_io::{DurableIoConfigError, DurableIoError, DurableIoPool};
mod key;
mod replay_signer;
mod replay_store;
mod seal;
mod terminal_store;

pub use epoch_store::{DurableFileError, SessionEpochStore, SessionEpochStoreError};
pub use key::{ProcessKeyError, ProcessX25519Key, X25519PublicKey};
pub use replay_signer::{ReplayProofSigner, ReplaySignerError, verify_replay_proof};
pub use replay_store::{
    ReplayControl, ReplayEnqueue, ReplayObligation, ReplayProofStore, ReplayStoreError,
    ReplayStoreLimits,
};
pub use seal::{
    MAX_PROCESS_KEYS, ProviderRequestSeal, SealKeyringError, SenderSealError, SenderSealKeyring,
    seal_for_provider, seal_request_for_provider,
};
pub use terminal_store::{
    TerminalDispositionStore, TerminalKey, TerminalRecord, TerminalResolution, TerminalStoreError,
};
