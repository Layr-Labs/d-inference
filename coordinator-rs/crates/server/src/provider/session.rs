//! Provider handshake plus bounded ownership of exactly one reader and writer.

use std::{fmt, sync::Arc, time::Duration};

use axum::extract::ws::Message;
use darkbloom_coordinator_protocol::v2::{ProviderId, RegistrationResponse};
use futures_util::{Sink, SinkExt, Stream, StreamExt};
use thiserror::Error;
use tokio::{task::JoinSet, time::timeout};

use super::{
    reader::{
        ProviderReadError, ProviderReader, ProviderReaderConfig, ProviderReaderConfigError,
        ProviderReaderExit, receive_registration,
    },
    registry::{ProviderRegistry, SessionActivationError, SessionLease, SessionReservationError},
    types::{
        RegistrationFrame, SessionEvent, SessionEventSendError, SessionEventSender, SessionIdentity,
    },
    writer::{
        ProviderWriterConfig, ProviderWriterConfigError, ProviderWriterError, ProviderWriterHandle,
        provider_writer,
    },
};

/// Handshake and task-shutdown policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProviderSessionConfig {
    /// Maximum time to receive the first registration frame.
    pub registration_timeout: Duration,
    /// Maximum time to put the generation-bound ACK on the wire.
    pub registration_ack_timeout: Duration,
    /// Common deadline to join both owned tasks after cancellation.
    pub task_join_timeout: Duration,
    /// Reader allocation bounds.
    pub reader: ProviderReaderConfig,
    /// Writer queue and delivery bounds.
    pub writer: ProviderWriterConfig,
}

impl Default for ProviderSessionConfig {
    fn default() -> Self {
        Self {
            registration_timeout: Duration::from_secs(10),
            registration_ack_timeout: Duration::from_secs(10),
            task_join_timeout: Duration::from_secs(5),
            reader: ProviderReaderConfig::default(),
            writer: ProviderWriterConfig::default(),
        }
    }
}

impl ProviderSessionConfig {
    fn validate(self) -> Result<Self, ProviderSessionConfigError> {
        if self.registration_timeout.is_zero() {
            return Err(ProviderSessionConfigError::ZeroRegistrationTimeout);
        }
        if self.registration_ack_timeout.is_zero() {
            return Err(ProviderSessionConfigError::ZeroAckTimeout);
        }
        if self.task_join_timeout.is_zero() {
            return Err(ProviderSessionConfigError::ZeroJoinTimeout);
        }
        self.reader
            .validate()
            .map_err(ProviderSessionConfigError::Reader)?;
        self.writer
            .validate()
            .map_err(ProviderSessionConfigError::Writer)?;
        Ok(self)
    }
}

/// Invalid session policy.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderSessionConfigError {
    /// Registration cannot wait forever.
    #[error("provider registration timeout must be greater than zero")]
    ZeroRegistrationTimeout,
    /// ACK send cannot wait forever.
    #[error("provider registration ACK timeout must be greater than zero")]
    ZeroAckTimeout,
    /// Reader/writer joins require a finite grace period.
    #[error("provider session task join timeout must be greater than zero")]
    ZeroJoinTimeout,
    /// Invalid reader policy.
    #[error(transparent)]
    Reader(ProviderReaderConfigError),
    /// Invalid writer policy.
    #[error(transparent)]
    Writer(ProviderWriterConfigError),
}

/// Handshake or owned-task failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ProviderSessionError {
    /// Invalid finite session policy.
    #[error(transparent)]
    Config(#[from] ProviderSessionConfigError),
    /// Registration read or decode failed.
    #[error(transparent)]
    Reader(#[from] ProviderReadError),
    /// Stable identity negotiation or epoch allocation failed.
    #[error(transparent)]
    Reservation(#[from] SessionReservationError),
    /// A newer concurrent registration superseded this ACK.
    #[error(transparent)]
    Activation(#[from] SessionActivationError),
    /// Writer policy was invalid before activation.
    #[error(transparent)]
    WriterConfig(#[from] ProviderWriterConfigError),
    /// ACK JSON serialization failed.
    #[error("failed to serialize provider registration ACK: {0}")]
    AckSerialization(Arc<str>),
    /// ACK send began but did not complete, so delivery is ambiguous.
    #[error("provider registration ACK delivery is unknown: {0}")]
    AckSentUnknown(Arc<str>),
    /// Activated registration could not enter the bounded downstream lane.
    #[error(transparent)]
    RegistrationEvent(#[from] SessionEventSendError),
    /// Reader task rejected a frame or lost its transport.
    #[error("provider reader task failed: {0}")]
    ReaderTask(ProviderReadError),
    /// Writer task timed out or lost its transport.
    #[error("provider writer task failed: {0}")]
    WriterTask(ProviderWriterError),
    /// A task wrapper panicked or was externally aborted.
    #[error("provider session task join failed: {0}")]
    TaskJoin(Arc<str>),
    /// Writer ended while the session was still current and uncancelled.
    #[error("provider writer exited before session cancellation")]
    UnexpectedWriterExit,
    /// Cancellation did not stop both owned tasks by the finite deadline.
    #[error("provider session task join exceeded {0:?}")]
    TaskJoinTimeout(Duration),
}

/// Clean complete-session outcome.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderSessionExit {
    /// Peer sent close or ended the WebSocket stream.
    PeerClosed,
    /// Registry replacement or coordinated shutdown cancelled this session.
    Cancelled,
}

enum SessionTaskResult {
    Reader(Result<ProviderReaderExit, ProviderReadError>),
    Writer(Result<(), ProviderWriterError>),
}

/// Activated session that owns every spawned task until joined or aborted.
pub struct ProviderSession {
    identity: SessionIdentity,
    registration: RegistrationFrame,
    writer: ProviderWriterHandle,
    cancellation: tokio_util::sync::CancellationToken,
    task_join_timeout: Duration,
    tasks: JoinSet<SessionTaskResult>,
    _lease: SessionLease,
}

impl fmt::Debug for ProviderSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderSession")
            .field("identity", &self.identity)
            .field("task_join_timeout", &self.task_join_timeout)
            .field("owned_tasks", &self.tasks.len())
            .finish_non_exhaustive()
    }
}

impl ProviderSession {
    /// Performs bounded registration, emits an ACK, activates atomically, then
    /// starts exactly one reader and exactly one writer task.
    pub async fn establish<S, E>(
        mut socket: S,
        stable_provider_id: ProviderId,
        registry: Arc<ProviderRegistry>,
        events: SessionEventSender,
        config: ProviderSessionConfig,
    ) -> Result<Self, ProviderSessionError>
    where
        S: Stream<Item = Result<Message, E>> + Sink<Message, Error = E> + Unpin + Send + 'static,
        E: fmt::Display + Send + 'static,
    {
        let config = config.validate()?;
        let registration =
            receive_registration(&mut socket, config.reader, config.registration_timeout).await?;
        let reservation = registry.reserve(stable_provider_id, registration.registration())?;

        let response = RegistrationResponse::RegisterAck(reservation.acknowledgement().clone());
        let ack = match serde_json::to_string(&response) {
            Ok(ack) => ack,
            Err(error) => {
                registry.abandon(&reservation);
                return Err(ProviderSessionError::AckSerialization(Arc::from(
                    error.to_string(),
                )));
            }
        };
        match timeout(
            config.registration_ack_timeout,
            socket.send(Message::Text(ack.into())),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                registry.abandon(&reservation);
                return Err(ProviderSessionError::AckSentUnknown(Arc::from(
                    error.to_string(),
                )));
            }
            Err(_) => {
                registry.abandon(&reservation);
                return Err(ProviderSessionError::AckSentUnknown(Arc::from(
                    "send timeout",
                )));
            }
        }

        let activation = registry.activate(&reservation)?;
        let identity = activation.lease.identity();
        let cancellation = activation.lease.cancellation_token();
        let (writer, writer_handle) = provider_writer(config.writer, cancellation.clone())?;
        let reader = ProviderReader::new(
            config.reader,
            identity,
            reservation.protocol().clone(),
            events.clone(),
            cancellation.clone(),
        )
        .map_err(ProviderSessionConfigError::Reader)?;

        if let Err(error) = events.try_send(SessionEvent::Registered {
            identity,
            protocol: reservation.protocol().clone(),
            registration: registration.clone(),
        }) {
            writer_handle.fence(Arc::from(
                "registration event could not enter bounded session lane",
            ));
            drop(activation.lease);
            return Err(error.into());
        }

        let (sink, stream) = socket.split();
        let mut tasks = JoinSet::new();
        tasks.spawn(async move { SessionTaskResult::Reader(reader.run(stream).await) });
        tasks.spawn(async move { SessionTaskResult::Writer(writer.run(sink).await) });
        debug_assert_eq!(tasks.len(), 2);

        Ok(Self {
            identity,
            registration,
            writer: writer_handle,
            cancellation,
            task_join_timeout: config.task_join_timeout,
            tasks,
            _lease: activation.lease,
        })
    }

    /// Exact current identity allocated in the ACK.
    #[must_use]
    pub const fn identity(&self) -> SessionIdentity {
        self.identity
    }

    /// Typed registration and exact signed source bytes.
    #[must_use]
    pub const fn registration(&self) -> &RegistrationFrame {
        &self.registration
    }

    /// Cloneable producer for the sole bounded writer task.
    #[must_use]
    pub fn writer(&self) -> ProviderWriterHandle {
        self.writer.clone()
    }

    /// Number of tasks this session currently owns (always two after establish).
    #[must_use]
    pub fn owned_task_count(&self) -> usize {
        self.tasks.len()
    }

    /// Waits for peer close, replacement, or task failure, then joins both tasks.
    pub async fn wait(mut self) -> Result<ProviderSessionExit, ProviderSessionError> {
        let primary = tokio::select! {
            biased;
            () = self.cancellation.cancelled() => Ok(ProviderSessionExit::Cancelled),
            result = self.tasks.join_next() => classify_primary_task(result, &self.cancellation),
        };
        self.stop_and_join().await?;
        primary
    }

    /// Starts cancellation and joins both owned tasks within the configured bound.
    pub async fn shutdown(mut self) -> Result<ProviderSessionExit, ProviderSessionError> {
        self.cancellation.cancel();
        self.writer
            .fence(Arc::from("provider session shutdown requested"));
        self.stop_and_join().await?;
        Ok(ProviderSessionExit::Cancelled)
    }

    async fn stop_and_join(&mut self) -> Result<(), ProviderSessionError> {
        self.cancellation.cancel();
        self.writer.fence(Arc::from("provider session stopping"));
        let drain = async {
            while let Some(joined) = self.tasks.join_next().await {
                // The primary task result is classified by `wait`; shutdown
                // only needs to guarantee ownership and bounded completion.
                if let Err(error) = joined
                    && !error.is_cancelled()
                {
                    return Err(ProviderSessionError::TaskJoin(Arc::from(error.to_string())));
                }
            }
            Ok(())
        };
        match timeout(self.task_join_timeout, drain).await {
            Ok(result) => result,
            Err(_) => {
                self.tasks.abort_all();
                while self.tasks.join_next().await.is_some() {}
                Err(ProviderSessionError::TaskJoinTimeout(
                    self.task_join_timeout,
                ))
            }
        }
    }
}

impl Drop for ProviderSession {
    fn drop(&mut self) {
        self.cancellation.cancel();
        self.writer
            .fence(Arc::from("provider session owner dropped"));
        self.tasks.abort_all();
        // Dropping JoinSet aborts and owns all join handles; no task detaches.
    }
}

fn classify_primary_task(
    result: Option<Result<SessionTaskResult, tokio::task::JoinError>>,
    cancellation: &tokio_util::sync::CancellationToken,
) -> Result<ProviderSessionExit, ProviderSessionError> {
    match result {
        Some(Ok(SessionTaskResult::Reader(Ok(ProviderReaderExit::PeerClosed)))) => {
            Ok(ProviderSessionExit::PeerClosed)
        }
        Some(Ok(SessionTaskResult::Reader(Ok(ProviderReaderExit::Cancelled)))) => {
            Ok(ProviderSessionExit::Cancelled)
        }
        Some(Ok(SessionTaskResult::Reader(Err(error)))) => {
            Err(ProviderSessionError::ReaderTask(error))
        }
        Some(Ok(SessionTaskResult::Writer(Err(error)))) => {
            Err(ProviderSessionError::WriterTask(error))
        }
        Some(Ok(SessionTaskResult::Writer(Ok(())))) if cancellation.is_cancelled() => {
            Ok(ProviderSessionExit::Cancelled)
        }
        Some(Ok(SessionTaskResult::Writer(Ok(())))) => {
            Err(ProviderSessionError::UnexpectedWriterExit)
        }
        Some(Err(error)) => Err(ProviderSessionError::TaskJoin(Arc::from(error.to_string()))),
        None => Err(ProviderSessionError::TaskJoin(Arc::from(
            "provider session task set became empty",
        ))),
    }
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        pin::Pin,
        sync::Mutex,
        task::{Context, Poll},
    };

    use base64::{Engine, engine::general_purpose::STANDARD};
    use darkbloom_coordinator_protocol::v2::{ProtocolCapabilities, ProviderProcessGenerationId};
    use futures_util::{Sink, Stream};

    use super::*;
    use crate::provider::{
        registry::ProviderRegistryConfig,
        types::{SessionEvent, session_event_channel},
    };

    fn capabilities() -> ProtocolCapabilities {
        ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 1,
            prepared_leases: true,
            start_authorization: true,
            structured_errors: true,
            start_ack: true,
            abort_ack: true,
            cancel_ack: true,
            durable_terminals: true,
            model_lifecycle_events: true,
            binary_payload_frames: true,
            coordinator_replay_fences: true,
            ..ProtocolCapabilities::default()
        }
    }

    fn registry() -> Arc<ProviderRegistry> {
        let mut raw = [0x44; 65];
        raw[0] = 0x04;
        Arc::new(
            ProviderRegistry::new(ProviderRegistryConfig {
                maximum_providers: 4,
                coordinator_capabilities: capabilities(),
                coordinator_replay_fence_public_key: Some(Arc::from(STANDARD.encode(raw))),
            })
            .expect("registry"),
        )
    }

    fn registration() -> String {
        let capabilities = serde_json::to_string(&capabilities()).expect("capabilities");
        format!(
            concat!(
                r#"{{"type":"register","hardware":{{"machine_model":"x","chip_name":"x","#,
                r#""chip_family":"x","chip_tier":"x","memory_gb":1,"memory_available_gb":1,"#,
                r#""cpu_cores":{{"total":1,"performance":1,"efficiency":0}},"gpu_cores":1,"#,
                r#""memory_bandwidth_gbs":1}},"models":[],"backend":"mlx","#,
                r#""provider_process_generation":"{}","protocol_capabilities":{}}}"#
            ),
            ProviderProcessGenerationId::new([2; 16]),
            capabilities
        )
    }

    #[tokio::test]
    async fn establishment_emits_generation_bound_ack_and_owns_two_tasks() {
        let writes = Arc::new(Mutex::new(Vec::new()));
        let socket = MockSocket {
            reads: VecDeque::from([Ok(Message::Text(registration().into()))]),
            writes: writes.clone(),
        };
        let (events, mut receiver) = session_event_channel(4).expect("events");
        let session = ProviderSession::establish(
            socket,
            ProviderId::new([1; 16]),
            registry(),
            events,
            ProviderSessionConfig {
                task_join_timeout: Duration::from_millis(50),
                ..ProviderSessionConfig::default()
            },
        )
        .await
        .expect("establish");
        assert_eq!(session.owned_task_count(), 2);
        let ack = {
            let writes = writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Message::Text(ack) = &writes[0] else {
                panic!("text ACK");
            };
            ack.to_string()
        };
        let ack: RegistrationResponse = serde_json::from_str(&ack).expect("typed ACK");
        let RegistrationResponse::RegisterAck(ack) = ack;
        assert_eq!(ack.provider_id, ProviderId::new([1; 16]));
        assert_eq!(
            ack.provider_process_generation,
            ProviderProcessGenerationId::new([2; 16])
        );
        assert!(ack.protocol_capabilities.is_some());
        assert!(matches!(
            receiver.recv().await,
            Some(SessionEvent::Registered { .. })
        ));
        session.shutdown().await.expect("bounded shutdown");
    }

    struct MockSocket {
        reads: VecDeque<Result<Message, MockError>>,
        writes: Arc<Mutex<Vec<Message>>>,
    }

    #[derive(Debug)]
    struct MockError;

    impl fmt::Display for MockError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("mock socket error")
        }
    }

    impl Stream for MockSocket {
        type Item = Result<Message, MockError>;

        fn poll_next(
            mut self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Option<Self::Item>> {
            Poll::Ready(self.reads.pop_front())
        }
    }

    impl Sink<Message> for MockSocket {
        type Error = MockError;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn start_send(self: Pin<&mut Self>, item: Message) -> Result<(), Self::Error> {
            self.writes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(item);
            Ok(())
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }
}
