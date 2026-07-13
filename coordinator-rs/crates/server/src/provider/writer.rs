//! Bounded two-lane provider writer with delivery ambiguity tracking.

use std::{
    collections::VecDeque,
    fmt,
    future::{Future, poll_fn},
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::Poll,
    time::Duration,
};

use axum::extract::ws::Message;
use futures_util::Sink;
use serde::Serialize;
use thiserror::Error;
use tokio::{
    sync::{Notify, oneshot, watch},
    time::timeout,
};
use tokio_util::sync::CancellationToken;

use crate::telemetry::datadog::{self, Metric, Tag, TagKey};

/// Item and byte bounds for one FIFO lane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WriterLaneLimits {
    /// Maximum queued and in-flight items in this lane.
    pub maximum_items: usize,
    /// Maximum queued and in-flight payload bytes in this lane.
    pub maximum_bytes: usize,
}

/// Total bounds, correctness reserve, fairness, and timeout policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProviderWriterConfig {
    /// Shared maximum queued and in-flight items.
    pub maximum_items: usize,
    /// Shared maximum queued and in-flight payload bytes.
    pub maximum_bytes: usize,
    /// Independent control-lane bounds.
    pub control: WriterLaneLimits,
    /// Independent data-lane bounds.
    pub data: WriterLaneLimits,
    /// Shared item slots that data is forbidden to consume.
    pub control_correctness_item_reserve: usize,
    /// Shared bytes that data is forbidden to consume.
    pub control_correctness_byte_reserve: usize,
    /// Consecutive controls allowed while data is waiting.
    pub maximum_control_burst: usize,
    /// Maximum duration of one sink send/flush.
    pub send_timeout: Duration,
    /// Maximum duration a caller waits for a delivery receipt.
    pub receipt_timeout: Duration,
}

impl Default for ProviderWriterConfig {
    fn default() -> Self {
        Self {
            maximum_items: 256,
            maximum_bytes: 8 * 1024 * 1024,
            control: WriterLaneLimits {
                maximum_items: 64,
                maximum_bytes: 512 * 1024,
            },
            data: WriterLaneLimits {
                maximum_items: 224,
                maximum_bytes: 8 * 1024 * 1024,
            },
            control_correctness_item_reserve: 8,
            control_correctness_byte_reserve: 64 * 1024,
            maximum_control_burst: 8,
            send_timeout: Duration::from_secs(10),
            receipt_timeout: Duration::from_secs(15),
        }
    }
}

impl ProviderWriterConfig {
    pub(crate) fn validate(self) -> Result<Self, ProviderWriterConfigError> {
        if self.maximum_items == 0
            || self.control.maximum_items == 0
            || self.data.maximum_items == 0
        {
            return Err(ProviderWriterConfigError::ZeroItemLimit);
        }
        if self.maximum_bytes == 0
            || self.control.maximum_bytes == 0
            || self.data.maximum_bytes == 0
        {
            return Err(ProviderWriterConfigError::ZeroByteLimit);
        }
        if self.control_correctness_item_reserve == 0
            || self.control_correctness_item_reserve >= self.maximum_items
        {
            return Err(ProviderWriterConfigError::InvalidItemReserve);
        }
        if self.control_correctness_byte_reserve == 0
            || self.control_correctness_byte_reserve >= self.maximum_bytes
        {
            return Err(ProviderWriterConfigError::InvalidByteReserve);
        }
        if self.maximum_control_burst == 0 {
            return Err(ProviderWriterConfigError::ZeroControlBurst);
        }
        if self.send_timeout.is_zero() {
            return Err(ProviderWriterConfigError::ZeroSendTimeout);
        }
        if self.receipt_timeout.is_zero() {
            return Err(ProviderWriterConfigError::ZeroReceiptTimeout);
        }
        Ok(self)
    }
}

/// Invalid finite writer policy.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderWriterConfigError {
    /// Every queue must hold at least one item.
    #[error("writer item limits must be greater than zero")]
    ZeroItemLimit,
    /// Every queue must account for at least one payload byte.
    #[error("writer byte limits must be greater than zero")]
    ZeroByteLimit,
    /// Data must leave a finite nonempty control item reserve.
    #[error("control item reserve must be in 1..maximum_items")]
    InvalidItemReserve,
    /// Data must leave a finite nonempty control byte reserve.
    #[error("control byte reserve must be in 1..maximum_bytes")]
    InvalidByteReserve,
    /// Fairness requires a positive control burst.
    #[error("maximum control burst must be greater than zero")]
    ZeroControlBurst,
    /// A socket send cannot wait forever.
    #[error("writer send timeout must be greater than zero")]
    ZeroSendTimeout,
    /// Receipt waiters cannot wait forever.
    #[error("writer receipt timeout must be greater than zero")]
    ZeroReceiptTimeout,
}

/// Outbound WebSocket payload owned by the writer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutboundFrame {
    /// JSON or other UTF-8 control/data text.
    Text(String),
    /// Opaque binary payload.
    Binary(Vec<u8>),
    /// Explicit WebSocket ping.
    Ping(Vec<u8>),
    /// Explicit WebSocket pong.
    Pong(Vec<u8>),
}

impl OutboundFrame {
    /// Serializes a typed JSON frame before queue accounting.
    pub fn json<T: Serialize>(value: &T) -> Result<Self, serde_json::Error> {
        serde_json::to_string(value).map(Self::Text)
    }

    /// Number of payload bytes charged to queue bounds.
    #[must_use]
    pub fn byte_len(&self) -> usize {
        match self {
            Self::Text(value) => value.len(),
            Self::Binary(value) | Self::Ping(value) | Self::Pong(value) => value.len(),
        }
    }

    fn into_message(self) -> Message {
        match self {
            Self::Text(value) => Message::Text(value.into()),
            Self::Binary(value) => Message::Binary(value.into()),
            Self::Ping(value) => Message::Ping(value.into()),
            Self::Pong(value) => Message::Pong(value.into()),
        }
    }
}

/// Observable delivery lifecycle of one accepted frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeliveryState {
    /// Accounted in a finite writer lane.
    Queued,
    /// Sink send and flush completed before the deadline.
    OnWire,
    /// Sending began, but timeout/cancellation/transport failure made delivery ambiguous.
    SentUnknown,
    /// Definitely never began sending.
    Failed(Arc<str>),
}

impl DeliveryState {
    /// Returns whether no later state transition is possible.
    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::OnWire | Self::SentUnknown | Self::Failed(_))
    }
}

/// Finite latest-value receipt for one accepted frame.
#[derive(Debug)]
pub struct DeliveryReceipt {
    state: watch::Receiver<DeliveryState>,
    wait_timeout: Duration,
    lane: WriterLane,
}

/// Queue-admitted frame held behind an explicit durable release gate.
///
/// Dropping this value before `commit` guarantees the writer reports
/// `Failed` without beginning a socket send.
#[derive(Debug)]
pub struct StagedDelivery {
    release: Option<oneshot::Sender<()>>,
    receipt: DeliveryReceipt,
}

impl StagedDelivery {
    #[must_use]
    pub fn commit(mut self) -> DeliveryReceipt {
        let release = self
            .release
            .take()
            .expect("staged delivery can only be committed once");
        let _ = release.send(());
        self.receipt
    }
}

impl DeliveryReceipt {
    /// Returns the latest delivery state without waiting.
    #[must_use]
    pub fn state(&self) -> DeliveryState {
        self.state.borrow().clone()
    }

    /// Waits only up to the configured receipt bound for a terminal state.
    pub async fn wait(mut self) -> Result<DeliveryState, DeliveryReceiptError> {
        let wait_timeout = self.wait_timeout;
        let wait = async {
            loop {
                let state = self.state();
                if state.is_terminal() {
                    return Ok(state);
                }
                self.state
                    .changed()
                    .await
                    .map_err(|_| DeliveryReceiptError::WriterUnavailable)?;
            }
        };
        match timeout(wait_timeout, wait).await {
            Ok(result) => result,
            Err(_) => {
                datadog::counter(
                    Metric::WriterTimeout,
                    1,
                    &[
                        Tag::new(TagKey::Kind, "receipt"),
                        Tag::new(TagKey::Lane, self.lane.as_str()),
                    ],
                );
                Err(DeliveryReceiptError::Timeout)
            }
        }
    }
}

/// Failure while awaiting a bounded receipt.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DeliveryReceiptError {
    /// No terminal result arrived before the receipt deadline.
    #[error("delivery receipt timed out")]
    Timeout,
    /// Writer disappeared without publishing a terminal result.
    #[error("provider writer became unavailable before receipt completion")]
    WriterUnavailable,
}

/// Queue lane selected by the caller.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WriterLane {
    Control,
    Data,
}

impl WriterLane {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Control => "control",
            Self::Data => "data",
        }
    }
}

/// Immediate queue-admission failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum WriterEnqueueError {
    /// Data saturation is retryable and does not fence the provider.
    #[error("provider writer data lane is saturated")]
    DataSaturated,
    /// Missing correctness control capacity makes the session unsafe.
    #[error("provider writer control lane is saturated; session fenced")]
    ControlSaturatedSessionFenced,
    /// Session has already closed or been fenced.
    #[error("provider writer is closed: {0}")]
    Closed(Arc<str>),
    /// Typed JSON serialization failed before queue mutation.
    #[error("failed to serialize provider frame: {0}")]
    Serialization(Arc<str>),
}

/// Absolute queue headroom including the current in-flight send.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WriterQueueHeadroom {
    /// Monotonic report revision.
    pub revision: u64,
    /// Shared item slots not currently accounted.
    pub available_items: usize,
    /// Shared payload bytes not currently accounted.
    pub available_bytes: usize,
    /// Items data can consume while preserving correctness reserve.
    pub data_available_items: usize,
    /// Bytes data can consume while preserving correctness reserve.
    pub data_available_bytes: usize,
}

struct QueuedFrame {
    lane: WriterLane,
    frame: OutboundFrame,
    bytes: usize,
    delivery: watch::Sender<DeliveryState>,
    release: Option<oneshot::Receiver<()>>,
}

impl fmt::Debug for QueuedFrame {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("QueuedFrame")
            .field("lane", &self.lane)
            .field("bytes", &self.bytes)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
struct QueueState {
    control: VecDeque<QueuedFrame>,
    data: VecDeque<QueuedFrame>,
    control_items: usize,
    control_bytes: usize,
    data_items: usize,
    data_bytes: usize,
    control_burst: usize,
    revision: u64,
    closed: Option<Arc<str>>,
}

impl Default for QueueState {
    fn default() -> Self {
        Self {
            control: VecDeque::new(),
            data: VecDeque::new(),
            control_items: 0,
            control_bytes: 0,
            data_items: 0,
            data_bytes: 0,
            control_burst: 0,
            revision: 1,
            closed: None,
        }
    }
}

impl QueueState {
    fn total_items(&self) -> usize {
        self.control_items.saturating_add(self.data_items)
    }

    fn total_bytes(&self) -> usize {
        self.control_bytes.saturating_add(self.data_bytes)
    }

    fn bump_revision(&mut self) {
        self.revision = self.revision.saturating_add(1);
    }
}

fn emit_queue_metrics(state: &QueueState) {
    for (lane, items, bytes) in [
        ("control", state.control_items, state.control_bytes),
        ("data", state.data_items, state.data_bytes),
    ] {
        let tags = [Tag::new(TagKey::Lane, lane)];
        datadog::histogram(Metric::WriterQueueItems, items as f64, &tags);
        datadog::histogram(Metric::WriterQueueBytes, bytes as f64, &tags);
    }
}

#[derive(Debug)]
struct WriterQueue {
    config: ProviderWriterConfig,
    state: Mutex<QueueState>,
    notify: Notify,
    cancellation: CancellationToken,
}

impl WriterQueue {
    fn try_enqueue(
        &self,
        lane: WriterLane,
        frame: OutboundFrame,
    ) -> Result<DeliveryReceipt, WriterEnqueueError> {
        let (receipt, _) = self.try_enqueue_inner(lane, frame, false)?;
        Ok(receipt)
    }

    fn try_stage(
        &self,
        lane: WriterLane,
        frame: OutboundFrame,
    ) -> Result<StagedDelivery, WriterEnqueueError> {
        let (receipt, release) = self.try_enqueue_inner(lane, frame, true)?;
        Ok(StagedDelivery { release, receipt })
    }

    fn try_enqueue_inner(
        &self,
        lane: WriterLane,
        frame: OutboundFrame,
        staged: bool,
    ) -> Result<(DeliveryReceipt, Option<oneshot::Sender<()>>), WriterEnqueueError> {
        let bytes = frame.byte_len();
        #[cfg(feature = "fault-injection")]
        if crate::fault::checkpoint_sync(
            crate::fault::FaultPoint::ProviderWriterSaturation,
            file!(),
            module_path!(),
            line!(),
            "WriterQueue::try_enqueue_inner",
        )
        .is_err()
        {
            if lane == WriterLane::Data {
                return Err(WriterEnqueueError::DataSaturated);
            }
            self.fence(Arc::from("injected control writer saturation"));
            return Err(WriterEnqueueError::ControlSaturatedSessionFenced);
        }
        let mut state = self.lock_state();
        if let Some(reason) = &state.closed {
            return Err(WriterEnqueueError::Closed(reason.clone()));
        }
        if !self.has_capacity(&state, lane, bytes) {
            if lane == WriterLane::Data {
                datadog::counter(
                    Metric::WriterDelivery,
                    1,
                    &[
                        Tag::new(TagKey::Lane, lane.as_str()),
                        Tag::new(TagKey::Outcome, "saturated"),
                    ],
                );
                return Err(WriterEnqueueError::DataSaturated);
            }
            datadog::counter(
                Metric::WriterDelivery,
                1,
                &[
                    Tag::new(TagKey::Lane, lane.as_str()),
                    Tag::new(TagKey::Outcome, "saturated"),
                ],
            );
            let reason: Arc<str> = Arc::from("control correctness capacity exhausted");
            Self::fail_queued_locked(&mut state, reason.clone());
            state.closed = Some(reason);
            drop(state);
            self.cancellation.cancel();
            self.notify.notify_waiters();
            return Err(WriterEnqueueError::ControlSaturatedSessionFenced);
        }

        let (delivery, receipt) = watch::channel(DeliveryState::Queued);
        let (release, release_wait) = if staged {
            let (release, wait) = oneshot::channel();
            (Some(release), Some(wait))
        } else {
            (None, None)
        };
        let queued = QueuedFrame {
            lane,
            frame,
            bytes,
            delivery,
            release: release_wait,
        };
        match lane {
            WriterLane::Control => {
                state.control_items += 1;
                state.control_bytes += bytes;
                state.control.push_back(queued);
            }
            WriterLane::Data => {
                state.data_items += 1;
                state.data_bytes += bytes;
                state.data.push_back(queued);
            }
        }
        state.bump_revision();
        emit_queue_metrics(&state);
        drop(state);
        self.notify.notify_one();
        Ok((
            DeliveryReceipt {
                state: receipt,
                wait_timeout: self.config.receipt_timeout,
                lane,
            },
            release,
        ))
    }

    fn has_capacity(&self, state: &QueueState, lane: WriterLane, bytes: usize) -> bool {
        let total_items = state.total_items();
        let total_bytes = state.total_bytes();
        let shared_fits = total_items < self.config.maximum_items
            && bytes <= self.config.maximum_bytes.saturating_sub(total_bytes);
        if !shared_fits {
            return false;
        }

        match lane {
            WriterLane::Control => {
                state.control_items < self.config.control.maximum_items
                    && bytes
                        <= self
                            .config
                            .control
                            .maximum_bytes
                            .saturating_sub(state.control_bytes)
            }
            WriterLane::Data => {
                state.data_items < self.config.data.maximum_items
                    && bytes
                        <= self
                            .config
                            .data
                            .maximum_bytes
                            .saturating_sub(state.data_bytes)
                    && total_items
                        < self
                            .config
                            .maximum_items
                            .saturating_sub(self.config.control_correctness_item_reserve)
                    && bytes
                        <= self
                            .config
                            .maximum_bytes
                            .saturating_sub(self.config.control_correctness_byte_reserve)
                            .saturating_sub(total_bytes)
            }
        }
    }

    async fn next(&self) -> Option<QueuedFrame> {
        loop {
            if self.cancellation.is_cancelled() {
                self.fence(Arc::from("provider session cancelled"));
                return None;
            }
            if let Some(item) = self.pop() {
                return Some(item);
            }
            let notified = self.notify.notified();
            if let Some(item) = self.pop() {
                return Some(item);
            }
            tokio::select! {
                biased;
                () = self.cancellation.cancelled() => {
                    self.fence(Arc::from("provider session cancelled"));
                    return None;
                }
                () = notified => {}
            }
        }
    }

    fn pop(&self) -> Option<QueuedFrame> {
        let mut state = self.lock_state();
        if state.closed.is_some() {
            return None;
        }
        let select_control = !state.control.is_empty()
            && (state.data.is_empty() || state.control_burst < self.config.maximum_control_burst);
        if select_control {
            state.control_burst = state.control_burst.saturating_add(1);
            state.control.pop_front()
        } else if !state.data.is_empty() {
            state.control_burst = 0;
            state.data.pop_front()
        } else {
            None
        }
    }

    fn complete(&self, lane: WriterLane, bytes: usize) {
        let mut state = self.lock_state();
        match lane {
            WriterLane::Control => {
                state.control_items = state.control_items.saturating_sub(1);
                state.control_bytes = state.control_bytes.saturating_sub(bytes);
            }
            WriterLane::Data => {
                state.data_items = state.data_items.saturating_sub(1);
                state.data_bytes = state.data_bytes.saturating_sub(bytes);
            }
        }
        state.bump_revision();
        emit_queue_metrics(&state);
    }

    fn fence(&self, reason: Arc<str>) {
        let mut state = self.lock_state();
        if state.closed.is_none() {
            Self::fail_queued_locked(&mut state, reason.clone());
            state.closed = Some(reason);
            state.bump_revision();
        }
        drop(state);
        self.cancellation.cancel();
        self.notify.notify_waiters();
    }

    fn fail_queued_locked(state: &mut QueueState, reason: Arc<str>) {
        let mut queued_frames: Vec<_> = state.control.drain(..).collect();
        queued_frames.extend(state.data.drain(..));
        for queued in queued_frames {
            let _ = queued
                .delivery
                .send_replace(DeliveryState::Failed(reason.clone()));
            match queued.lane {
                WriterLane::Control => {
                    state.control_items = state.control_items.saturating_sub(1);
                    state.control_bytes = state.control_bytes.saturating_sub(queued.bytes);
                }
                WriterLane::Data => {
                    state.data_items = state.data_items.saturating_sub(1);
                    state.data_bytes = state.data_bytes.saturating_sub(queued.bytes);
                }
            }
        }
    }

    fn headroom(&self) -> WriterQueueHeadroom {
        let state = self.lock_state();
        let available_items = self
            .config
            .maximum_items
            .saturating_sub(state.total_items());
        let available_bytes = self
            .config
            .maximum_bytes
            .saturating_sub(state.total_bytes());
        WriterQueueHeadroom {
            revision: state.revision,
            available_items,
            available_bytes,
            data_available_items: available_items
                .saturating_sub(self.config.control_correctness_item_reserve),
            data_available_bytes: available_bytes
                .saturating_sub(self.config.control_correctness_byte_reserve),
        }
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, QueueState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Cloneable admission handle for the sole writer task.
#[derive(Clone, Debug)]
pub struct ProviderWriterHandle {
    queue: Arc<WriterQueue>,
}

impl ProviderWriterHandle {
    /// Enqueues correctness traffic. Saturation fences the complete session.
    pub fn try_send_control(
        &self,
        frame: OutboundFrame,
    ) -> Result<DeliveryReceipt, WriterEnqueueError> {
        self.queue.try_enqueue(WriterLane::Control, frame)
    }

    /// Serializes and enqueues typed correctness traffic.
    pub fn try_send_control_json<T: Serialize>(
        &self,
        value: &T,
    ) -> Result<DeliveryReceipt, WriterEnqueueError> {
        let frame = OutboundFrame::json(value)
            .map_err(|error| WriterEnqueueError::Serialization(Arc::from(error.to_string())))?;
        self.try_send_control(frame)
    }

    /// Reserves control-lane capacity without allowing the socket send to
    /// begin. The caller durably records `queued` and then commits the stage.
    pub fn try_stage_control_json<T: Serialize>(
        &self,
        value: &T,
    ) -> Result<StagedDelivery, WriterEnqueueError> {
        let frame = OutboundFrame::json(value)
            .map_err(|error| WriterEnqueueError::Serialization(Arc::from(error.to_string())))?;
        self.queue.try_stage(WriterLane::Control, frame)
    }

    /// Enqueues ordinary request/data traffic without consuming control reserve.
    pub fn try_send_data(
        &self,
        frame: OutboundFrame,
    ) -> Result<DeliveryReceipt, WriterEnqueueError> {
        self.queue.try_enqueue(WriterLane::Data, frame)
    }

    /// Serializes and enqueues ordinary typed traffic.
    pub fn try_send_data_json<T: Serialize>(
        &self,
        value: &T,
    ) -> Result<DeliveryReceipt, WriterEnqueueError> {
        let frame = OutboundFrame::json(value)
            .map_err(|error| WriterEnqueueError::Serialization(Arc::from(error.to_string())))?;
        self.try_send_data(frame)
    }

    /// Returns absolute headroom suitable for fleet admission reports.
    #[must_use]
    pub fn headroom(&self) -> WriterQueueHeadroom {
        self.queue.headroom()
    }

    /// Fences the session and definitely fails every not-yet-started frame.
    pub fn fence(&self, reason: impl Into<Arc<str>>) {
        self.queue.fence(reason.into());
    }

    #[cfg(test)]
    pub(crate) fn exhaust_control_capacity_for_test(&self) {
        let mut state = self.queue.lock_state();
        state.control_items = self.queue.config.control.maximum_items;
        state.bump_revision();
    }
}

/// Creates the sole writer task's queue and producer handle.
pub fn provider_writer(
    config: ProviderWriterConfig,
    cancellation: CancellationToken,
) -> Result<(ProviderWriter, ProviderWriterHandle), ProviderWriterConfigError> {
    let config = config.validate()?;
    let queue = Arc::new(WriterQueue {
        config,
        state: Mutex::new(QueueState::default()),
        notify: Notify::new(),
        cancellation,
    });
    Ok((
        ProviderWriter {
            queue: queue.clone(),
        },
        ProviderWriterHandle { queue },
    ))
}

/// Sole consumer of both outbound lanes.
#[derive(Debug)]
pub struct ProviderWriter {
    queue: Arc<WriterQueue>,
}

/// Fatal writer task result.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ProviderWriterError {
    /// Send/flush did not complete by the finite per-frame deadline.
    #[error("provider WebSocket send timed out after {0:?}")]
    SendTimeout(Duration),
    /// Transport failure while attempting to send a provider frame.
    #[error("provider WebSocket send failed: {0}")]
    Transport(Arc<str>),
}

impl ProviderWriter {
    /// Runs one and only one sink owner until cancellation or fatal send error.
    pub async fn run<S, E>(self, mut sink: S) -> Result<(), ProviderWriterError>
    where
        S: Sink<Message, Error = E> + Unpin,
        E: fmt::Display,
    {
        while let Some(item) = self.queue.next().await {
            if self.queue.cancellation.is_cancelled() {
                let _ = item.delivery.send_replace(DeliveryState::Failed(Arc::from(
                    "provider session cancelled",
                )));
                self.queue.complete(item.lane, item.bytes);
                break;
            }

            let lane = item.lane;
            let bytes = item.bytes;
            let delivery = item.delivery;
            #[cfg(feature = "fault-injection")]
            let staged = item.release.is_some();
            if let Some(release) = item.release {
                let released = tokio::select! {
                    biased;
                    () = self.queue.cancellation.cancelled() => false,
                    result = release => result.is_ok(),
                };
                if !released {
                    let _ = delivery.send_replace(DeliveryState::Failed(Arc::from(
                        "staged provider frame was not durably released",
                    )));
                    self.queue.complete(lane, bytes);
                    continue;
                }
            }
            #[cfg(feature = "fault-injection")]
            let yield_after_start =
                staged && crate::fault::is_armed(crate::fault::FaultPoint::StartSentUnknown);
            #[cfg(not(feature = "fault-injection"))]
            let yield_after_start = false;
            let send_started = AtomicBool::new(false);
            let send = send_frame(
                &mut sink,
                item.frame.into_message(),
                yield_after_start,
                &send_started,
            );
            tokio::pin!(send);
            let first_poll =
                poll_fn(|context| Poll::Ready(Future::poll(send.as_mut(), context))).await;
            let result = match first_poll {
                Poll::Ready(Ok(())) => SendResult::OnWire,
                Poll::Ready(Err(error)) => SendResult::Transport {
                    error: Arc::from(error.to_string()),
                    started: send_started.load(Ordering::Acquire),
                },
                Poll::Pending if send_started.load(Ordering::Acquire) => {
                    #[cfg(feature = "fault-injection")]
                    if staged
                        && crate::fault::checkpoint_async(
                            crate::fault::FaultPoint::StartSentUnknown,
                            file!(),
                            module_path!(),
                            line!(),
                            "ProviderWriter::run",
                        )
                        .await
                        .is_err()
                    {
                        SendResult::InjectedAmbiguity
                    } else {
                        await_send_result(
                            &self.queue.cancellation,
                            self.queue.config.send_timeout,
                            &mut send,
                            &send_started,
                        )
                        .await
                    }
                    #[cfg(not(feature = "fault-injection"))]
                    {
                        await_send_result(
                            &self.queue.cancellation,
                            self.queue.config.send_timeout,
                            &mut send,
                            &send_started,
                        )
                        .await
                    }
                }
                Poll::Pending => {
                    await_send_result(
                        &self.queue.cancellation,
                        self.queue.config.send_timeout,
                        &mut send,
                        &send_started,
                    )
                    .await
                }
            };

            match result {
                SendResult::OnWire => {
                    datadog::counter(
                        Metric::WriterDelivery,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Outcome, "on_wire"),
                        ],
                    );
                    let _ = delivery.send_replace(DeliveryState::OnWire);
                    self.queue.complete(lane, bytes);
                }
                SendResult::Cancelled { started } => {
                    let outcome = if started { "sent_unknown" } else { "failed" };
                    datadog::counter(
                        Metric::WriterDelivery,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Outcome, outcome),
                        ],
                    );
                    let state = if started {
                        DeliveryState::SentUnknown
                    } else {
                        DeliveryState::Failed(Arc::from("provider session cancelled before send"))
                    };
                    let _ = delivery.send_replace(state);
                    self.queue.complete(lane, bytes);
                    self.queue.fence(Arc::from(if started {
                        "provider session cancelled during send"
                    } else {
                        "provider session cancelled before send"
                    }));
                    break;
                }
                SendResult::InjectedAmbiguity => {
                    datadog::counter(
                        Metric::WriterDelivery,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Outcome, "sent_unknown"),
                        ],
                    );
                    let _ = delivery.send_replace(DeliveryState::SentUnknown);
                    self.queue.complete(lane, bytes);
                    self.queue
                        .fence(Arc::from("provider session faulted during send"));
                    break;
                }
                SendResult::TimedOut { started } => {
                    datadog::counter(
                        Metric::WriterTimeout,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Kind, "send"),
                        ],
                    );
                    let outcome = if started { "sent_unknown" } else { "failed" };
                    datadog::counter(
                        Metric::WriterDelivery,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Outcome, outcome),
                        ],
                    );
                    let state = if started {
                        DeliveryState::SentUnknown
                    } else {
                        DeliveryState::Failed(Arc::from(
                            "provider WebSocket send timed out before send",
                        ))
                    };
                    let _ = delivery.send_replace(state);
                    self.queue.complete(lane, bytes);
                    self.queue
                        .fence(Arc::from("provider WebSocket send timed out"));
                    return Err(ProviderWriterError::SendTimeout(
                        self.queue.config.send_timeout,
                    ));
                }
                SendResult::Transport { error, started } => {
                    let outcome = if started { "sent_unknown" } else { "failed" };
                    datadog::counter(
                        Metric::WriterDelivery,
                        1,
                        &[
                            Tag::new(TagKey::Lane, lane.as_str()),
                            Tag::new(TagKey::Outcome, outcome),
                        ],
                    );
                    let state = if started {
                        DeliveryState::SentUnknown
                    } else {
                        DeliveryState::Failed(Arc::from(format!(
                            "provider WebSocket send failed before send: {error}"
                        )))
                    };
                    let _ = delivery.send_replace(state);
                    self.queue.complete(lane, bytes);
                    self.queue.fence(Arc::from(format!(
                        "provider WebSocket send failed: {error}"
                    )));
                    return Err(ProviderWriterError::Transport(error));
                }
            }
        }
        Ok(())
    }
}

enum SendResult {
    OnWire,
    Cancelled { started: bool },
    InjectedAmbiguity,
    TimedOut { started: bool },
    Transport { error: Arc<str>, started: bool },
}

fn send_frame<'a, S, E>(
    sink: &'a mut S,
    message: Message,
    mut yield_after_start: bool,
    started_signal: &'a AtomicBool,
) -> impl Future<Output = Result<(), E>> + 'a
where
    S: Sink<Message, Error = E> + Unpin + 'a,
{
    let mut message = Some(message);
    let mut started = false;
    poll_fn(move |context| {
        if !started {
            match Pin::new(&mut *sink).poll_ready(context) {
                Poll::Ready(Ok(())) => {}
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => return Poll::Pending,
            }
            if let Err(error) =
                Pin::new(&mut *sink).start_send(message.take().expect("provider frame starts once"))
            {
                return Poll::Ready(Err(error));
            }
            started = true;
            started_signal.store(true, Ordering::Release);
            if yield_after_start {
                yield_after_start = false;
                context.waker().wake_by_ref();
                return Poll::Pending;
            }
        }
        Pin::new(&mut *sink).poll_flush(context)
    })
}

async fn await_send_result<F, E>(
    cancellation: &CancellationToken,
    send_timeout: Duration,
    send: &mut Pin<&mut F>,
    started_signal: &AtomicBool,
) -> SendResult
where
    F: Future<Output = Result<(), E>>,
    E: fmt::Display,
{
    tokio::select! {
        biased;
        () = cancellation.cancelled() => SendResult::Cancelled {
            started: started_signal.load(Ordering::Acquire),
        },
        result = timeout(send_timeout, send) => {
            match result {
                Ok(Ok(())) => SendResult::OnWire,
                Ok(Err(error)) => SendResult::Transport {
                    error: Arc::from(error.to_string()),
                    started: started_signal.load(Ordering::Acquire),
                },
                Err(_) => SendResult::TimedOut {
                    started: started_signal.load(Ordering::Acquire),
                },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        convert::Infallible,
        pin::Pin,
        sync::atomic::{AtomicUsize, Ordering},
        task::{Context, Poll},
    };

    use futures_util::{Sink, poll};
    use tokio::{sync::mpsc, time::timeout};

    use super::*;

    fn config() -> ProviderWriterConfig {
        ProviderWriterConfig {
            maximum_items: 6,
            maximum_bytes: 60,
            control: WriterLaneLimits {
                maximum_items: 6,
                maximum_bytes: 60,
            },
            data: WriterLaneLimits {
                maximum_items: 6,
                maximum_bytes: 60,
            },
            control_correctness_item_reserve: 2,
            control_correctness_byte_reserve: 20,
            maximum_control_burst: 2,
            send_timeout: Duration::from_millis(20),
            receipt_timeout: Duration::from_millis(20),
        }
    }

    fn channel_sink(
        sender: mpsc::Sender<Message>,
    ) -> Pin<Box<dyn Sink<Message, Error = Infallible> + Send>> {
        Box::pin(futures_util::sink::unfold(
            sender,
            |sender, message| async move {
                sender.send(message).await.expect("receiver");
                Ok::<_, Infallible>(sender)
            },
        ))
    }

    #[tokio::test]
    async fn control_burst_yields_to_waiting_data_then_resumes_fifo() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        for value in ["c1", "c2", "c3"] {
            handle
                .try_send_control(OutboundFrame::Text(value.into()))
                .expect("control");
        }
        handle
            .try_send_data(OutboundFrame::Text("d1".into()))
            .expect("data");
        let (sender, mut receiver) = mpsc::channel(16);
        let task = tokio::spawn(writer.run(channel_sink(sender)));
        let mut observed = Vec::new();
        for _ in 0..4 {
            let Message::Text(value) = receiver.recv().await.expect("message") else {
                panic!("text");
            };
            observed.push(value.to_string());
        }
        assert_eq!(observed, ["c1", "c2", "d1", "c3"]);
        cancellation.cancel();
        task.await.expect("join").expect("clean cancellation");
    }

    #[tokio::test]
    async fn each_lane_is_fifo() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        for value in ["d1", "d2", "d3"] {
            handle
                .try_send_data(OutboundFrame::Text(value.into()))
                .expect("data");
        }
        let (sender, mut receiver) = mpsc::channel(16);
        let task = tokio::spawn(writer.run(channel_sink(sender)));
        for expected in ["d1", "d2", "d3"] {
            let Message::Text(actual) = receiver.recv().await.expect("message") else {
                panic!("text");
            };
            assert_eq!(actual, expected);
        }
        cancellation.cancel();
        task.await.expect("join").expect("clean cancellation");
    }

    #[test]
    fn data_saturation_preserves_control_correctness_reserve() {
        let cancellation = CancellationToken::new();
        let (_writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        for _ in 0..4 {
            handle
                .try_send_data(OutboundFrame::Text("1234567890".into()))
                .expect("within data allocation");
        }
        assert!(matches!(
            handle.try_send_data(OutboundFrame::Text("x".into())),
            Err(WriterEnqueueError::DataSaturated)
        ));
        assert!(!cancellation.is_cancelled());
        handle
            .try_send_control(OutboundFrame::Text("control".into()))
            .expect("reserved control capacity");
    }

    #[tokio::test]
    async fn full_control_lane_fences_session_and_fails_queued_receipts() {
        let mut bounded = config();
        bounded.control.maximum_items = 1;
        let cancellation = CancellationToken::new();
        let (_writer, handle) = provider_writer(bounded, cancellation.clone()).expect("writer");
        let receipt = handle
            .try_send_control(OutboundFrame::Text("first".into()))
            .expect("first control");
        assert!(matches!(
            handle.try_send_control(OutboundFrame::Text("second".into())),
            Err(WriterEnqueueError::ControlSaturatedSessionFenced)
        ));
        assert!(cancellation.is_cancelled());
        assert!(matches!(
            receipt.wait().await.expect("terminal receipt"),
            DeliveryState::Failed(_)
        ));
    }

    #[tokio::test]
    async fn successful_send_transitions_queued_to_on_wire() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let receipt = handle
            .try_send_data(OutboundFrame::Text("data".into()))
            .expect("enqueue");
        assert_eq!(receipt.state(), DeliveryState::Queued);
        let (sender, mut receiver) = mpsc::channel(16);
        let task = tokio::spawn(writer.run(channel_sink(sender)));
        receiver.recv().await.expect("wire message");
        assert_eq!(
            receipt.wait().await.expect("receipt"),
            DeliveryState::OnWire
        );
        cancellation.cancel();
        task.await.expect("join").expect("clean cancellation");
    }

    #[tokio::test]
    async fn staged_frame_cannot_reach_the_wire_before_durable_release() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let baseline = handle.headroom();
        let staged = handle
            .try_stage_control_json(&serde_json::json!({"type": "start"}))
            .expect("stage control frame");
        let (sender, mut receiver) = mpsc::channel(16);
        let task = tokio::spawn(writer.run(channel_sink(sender)));
        assert!(
            timeout(Duration::from_millis(5), receiver.recv())
                .await
                .is_err(),
            "staged Start reached the sink before its durable release"
        );
        drop(staged);
        timeout(Duration::from_millis(20), async {
            loop {
                if handle.headroom().available_items == baseline.available_items {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("dropped staged frame releases queue capacity");
        assert!(
            timeout(Duration::from_millis(5), receiver.recv())
                .await
                .is_err(),
            "dropped staged Start reached the sink"
        );
        cancellation.cancel();
        task.await.expect("join").expect("clean cancellation");
    }

    #[tokio::test]
    async fn durably_released_staged_frame_reports_on_wire() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let staged = handle
            .try_stage_control_json(&serde_json::json!({"type": "start"}))
            .expect("stage control frame");
        let (sender, mut receiver) = mpsc::channel(16);
        let task = tokio::spawn(writer.run(channel_sink(sender)));
        let receipt = staged.commit();
        receiver.recv().await.expect("released wire message");
        assert_eq!(
            receipt.wait().await.expect("staged delivery receipt"),
            DeliveryState::OnWire
        );
        cancellation.cancel();
        task.await.expect("join").expect("clean cancellation");
    }

    #[tokio::test]
    async fn send_timeout_is_sent_unknown_and_fences_followers() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let ambiguous = handle
            .try_send_control(OutboundFrame::Text("first".into()))
            .expect("first");
        let failed = handle
            .try_send_data(OutboundFrame::Text("second".into()))
            .expect("second");
        let result = writer.run(PendingSink).await;
        assert!(matches!(result, Err(ProviderWriterError::SendTimeout(_))));
        assert_eq!(
            ambiguous.wait().await.expect("ambiguous"),
            DeliveryState::SentUnknown
        );
        assert!(matches!(
            failed.wait().await.expect("failed follower"),
            DeliveryState::Failed(_)
        ));
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn timeout_before_sink_ownership_is_definitely_unsent() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let unsent = handle
            .try_send_control(OutboundFrame::Text("first".into()))
            .expect("first");
        let result = writer.run(NeverReadySink).await;
        assert!(matches!(result, Err(ProviderWriterError::SendTimeout(_))));
        assert!(matches!(
            unsent.wait().await.expect("definitely-unsent receipt"),
            DeliveryState::Failed(_)
        ));
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn transport_failure_before_sink_ownership_is_definitely_unsent() {
        let cancellation = CancellationToken::new();
        let (writer, handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let unsent = handle
            .try_send_control(OutboundFrame::Text("first".into()))
            .expect("first");
        let result = writer.run(ReadyErrorSink).await;
        assert!(matches!(
            result,
            Err(ProviderWriterError::Transport(error)) if error.as_ref() == "poll_ready failed"
        ));
        assert!(matches!(
            unsent.wait().await.expect("definitely-unsent receipt"),
            DeliveryState::Failed(_)
        ));
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn ambiguous_pending_edge_occurs_only_after_sink_owns_frame() {
        let starts = Arc::new(AtomicUsize::new(0));
        let mut sink = ObservedPendingSink {
            starts: starts.clone(),
        };
        let started_signal = AtomicBool::new(false);
        let send = send_frame(
            &mut sink,
            Message::Text("start".into()),
            true,
            &started_signal,
        );
        tokio::pin!(send);
        assert!(matches!(poll!(&mut send), Poll::Pending));
        assert!(started_signal.load(Ordering::Acquire));
        assert_eq!(
            starts.load(Ordering::Acquire),
            1,
            "ambiguous edge fired before start_send transferred ownership"
        );
    }

    #[tokio::test]
    async fn receipt_wait_is_independently_bounded() {
        let cancellation = CancellationToken::new();
        let (_writer, handle) = provider_writer(config(), cancellation).expect("writer");
        let receipt = handle
            .try_send_data(OutboundFrame::Text("never consumed".into()))
            .expect("enqueue");
        assert_eq!(receipt.wait().await, Err(DeliveryReceiptError::Timeout));
    }

    struct PendingSink;
    struct NeverReadySink;
    struct ReadyErrorSink;

    struct ObservedPendingSink {
        starts: Arc<AtomicUsize>,
    }

    impl Sink<Message> for ObservedPendingSink {
        type Error = Infallible;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn start_send(self: Pin<&mut Self>, _item: Message) -> Result<(), Self::Error> {
            self.starts.fetch_add(1, Ordering::AcqRel);
            Ok(())
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Pending
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    impl Sink<Message> for NeverReadySink {
        type Error = Infallible;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Pending
        }

        fn start_send(self: Pin<&mut Self>, _item: Message) -> Result<(), Self::Error> {
            panic!("start_send must not run while poll_ready is pending")
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            panic!("poll_flush must not run before start_send")
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    impl Sink<Message> for ReadyErrorSink {
        type Error = &'static str;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Err("poll_ready failed"))
        }

        fn start_send(self: Pin<&mut Self>, _item: Message) -> Result<(), Self::Error> {
            panic!("start_send must not run after poll_ready fails")
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            panic!("poll_flush must not run before start_send")
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    impl Sink<Message> for PendingSink {
        type Error = Infallible;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn start_send(self: Pin<&mut Self>, _item: Message) -> Result<(), Self::Error> {
            Ok(())
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Pending
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    #[test]
    fn headroom_counts_items_and_bytes_including_queued_work() {
        let cancellation = CancellationToken::new();
        let (_writer, handle) = provider_writer(config(), cancellation).expect("writer");
        let baseline = handle.headroom();
        handle
            .try_send_data(OutboundFrame::Binary(vec![0; 7]))
            .expect("enqueue");
        let after = handle.headroom();
        assert!(after.revision > baseline.revision);
        assert_eq!(after.available_items, baseline.available_items - 1);
        assert_eq!(after.available_bytes, baseline.available_bytes - 7);
    }

    #[tokio::test]
    async fn cancellation_join_is_prompt_when_writer_is_idle() {
        let cancellation = CancellationToken::new();
        let (writer, _handle) = provider_writer(config(), cancellation.clone()).expect("writer");
        let task = tokio::spawn(writer.run(futures_util::sink::drain()));
        cancellation.cancel();
        timeout(Duration::from_millis(50), task)
            .await
            .expect("bounded join")
            .expect("task join")
            .expect("writer result");
    }
}
