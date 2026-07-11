//! Cryptographic process identity, sealing, and durable replay support.

pub(crate) mod epoch_store;
mod key;
mod replay_signer;
mod replay_store;
mod seal;
mod terminal_store;

pub use epoch_store::{DurableFileError, SessionEpochStore, SessionEpochStoreError};
pub use key::{ProcessKeyError, ProcessX25519Key, X25519PublicKey};
pub use replay_signer::{ReplayProofSigner, ReplaySignerError, verify_replay_proof};
pub use replay_store::{
    ReplayControl, ReplayEnqueue, ReplayProofStore, ReplayStoreError, ReplayStoreLimits,
};
pub use seal::{
    MAX_PROCESS_KEYS, SealKeyringError, SenderSealError, SenderSealKeyring, seal_for_provider,
};
pub use terminal_store::{
    TerminalDispositionStore, TerminalKey, TerminalRecord, TerminalResolution, TerminalStoreError,
};
