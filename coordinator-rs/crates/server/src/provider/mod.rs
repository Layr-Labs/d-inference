//! Bounded, generation-fenced provider WebSocket sessions.
//!
//! The module is intentionally independent of HTTP route wiring and fleet
//! translation. Authentication supplies one stable protocol [`ProviderId`];
//! this layer owns monotonic session epochs, strict wire decoding, and exactly
//! one reader/writer task for the resulting WebSocket.

mod reader;
mod registry;
mod session;
mod types;
mod writer;

pub use reader::{
    MAX_PROVIDER_JSON_BYTES, ProviderReadError, ProviderReader, ProviderReaderConfig,
    ProviderReaderConfigError, ProviderReaderExit, parse_registration_frame, receive_registration,
};
pub use registry::{
    ProviderRegistry, ProviderRegistryConfig, ProviderRegistryConfigError, SessionActivation,
    SessionActivationError, SessionLease, SessionReservation, SessionReservationError,
};
pub use session::{
    ProviderSession, ProviderSessionConfig, ProviderSessionConfigError, ProviderSessionError,
    ProviderSessionExit,
};
pub use types::{
    BinarySessionFrame, MAX_SESSION_EVENT_CAPACITY, NegotiatedProtocol, RegistrationFrame,
    SessionEvent, SessionEventChannelConfigError, SessionEventReceiver, SessionEventSendError,
    SessionEventSender, SessionIdentity, session_event_channel,
};
pub use writer::{
    DeliveryReceipt, DeliveryReceiptError, DeliveryState, OutboundFrame, ProviderWriter,
    ProviderWriterConfig, ProviderWriterConfigError, ProviderWriterError, ProviderWriterHandle,
    StagedDelivery, WriterEnqueueError, WriterLaneLimits, WriterQueueHeadroom, provider_writer,
};

pub use darkbloom_coordinator_protocol::v2::ProviderId;
