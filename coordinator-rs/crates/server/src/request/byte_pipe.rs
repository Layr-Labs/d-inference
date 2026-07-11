//! A direct, nonblocking producer pipe bounded by both items and bytes.
//!
//! Provider-reader code calls [`BytePipeSender::try_send`]; it never awaits
//! consumer progress. Saturation atomically closes the pipe and fires the
//! request cancellation hook once. Already accepted items remain drainable, so
//! an overflow is observable rather than a silent drop.

use std::{
    collections::VecDeque,
    fmt,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, Ordering},
    },
};

use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use super::error::{CancellationReason, PipeCloseReason, PipeConfigError, PipeError};

/// Process hard bound for a single direct pipe's resident items.
pub const MAX_PIPE_ITEMS: usize = 65_536;
/// Process hard bound for a single direct pipe's resident bytes.
pub const MAX_PIPE_BYTES: usize = 64 * 1024 * 1024;

/// Reports the exact resident byte charge for an item.
pub trait PipeItem {
    /// Bytes retained while this item is queued.
    fn pipe_bytes(&self) -> usize;
}

impl PipeItem for Vec<u8> {
    fn pipe_bytes(&self) -> usize {
        self.len()
    }
}

impl PipeItem for Arc<[u8]> {
    fn pipe_bytes(&self) -> usize {
        self.len()
    }
}

impl PipeItem for String {
    fn pipe_bytes(&self) -> usize {
        self.len()
    }
}

/// Finite resident limits for a direct pipe.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BytePipeLimits {
    /// Maximum accepted but not yet received items.
    pub maximum_items: usize,
    /// Maximum accepted but not yet received bytes.
    pub maximum_bytes: usize,
}

impl BytePipeLimits {
    /// Validates finite nonzero limits against process hard bounds.
    pub const fn validate(self) -> Result<Self, PipeConfigError> {
        if self.maximum_items == 0 {
            return Err(PipeConfigError::ZeroItems);
        }
        if self.maximum_bytes == 0 {
            return Err(PipeConfigError::ZeroBytes);
        }
        if self.maximum_items > MAX_PIPE_ITEMS {
            return Err(PipeConfigError::TooManyItems {
                actual: self.maximum_items,
                maximum: MAX_PIPE_ITEMS,
            });
        }
        if self.maximum_bytes > MAX_PIPE_BYTES {
            return Err(PipeConfigError::TooManyBytes {
                actual: self.maximum_bytes,
                maximum: MAX_PIPE_BYTES,
            });
        }
        Ok(self)
    }
}

/// Snapshot of direct-pipe occupancy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BytePipeStats {
    /// Accepted items waiting for the receiver.
    pub queued_items: usize,
    /// Exact resident bytes waiting for the receiver.
    pub queued_bytes: usize,
    /// Terminal close reason, absent for graceful EOF and an open pipe.
    pub close_reason: Option<PipeCloseReason>,
    /// Whether no future sends can succeed.
    pub is_closed: bool,
}

type CancellationCallback = dyn Fn(CancellationReason) + Send + Sync + 'static;

struct CancellationInner {
    token: CancellationToken,
    state: AtomicU8,
    callback: Arc<CancellationCallback>,
}

const CANCELLATION_ACTIVE: u8 = 0;
const CANCELLATION_FIRED: u8 = 1;
const CANCELLATION_COMPLETED: u8 = 2;

/// One request-scoped cancellation signal shared by every execution primitive.
///
/// The token and callback are installed when this value is constructed, before
/// any request command can be enqueued or awaited. Every caller may race to
/// cancel, but only the winner invokes the callback.
#[derive(Clone)]
pub struct RequestCancellation {
    inner: Arc<CancellationInner>,
}

impl fmt::Debug for RequestCancellation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RequestCancellation")
            .field("is_cancelled", &self.is_cancelled())
            .finish_non_exhaustive()
    }
}

impl RequestCancellation {
    /// Installs the token and immediate cancellation hook.
    #[must_use]
    pub fn new(
        token: CancellationToken,
        callback: impl Fn(CancellationReason) + Send + Sync + 'static,
    ) -> Self {
        Self {
            inner: Arc::new(CancellationInner {
                token,
                state: AtomicU8::new(CANCELLATION_ACTIVE),
                callback: Arc::new(callback),
            }),
        }
    }

    /// Creates a cancellation signal without an external hook.
    #[must_use]
    pub fn token_only(token: CancellationToken) -> Self {
        Self::new(token, |_| {})
    }

    /// Fires cancellation at most once. The token is cancelled before the
    /// synchronous hook runs, so concurrent tasks observe cancellation
    /// immediately even if the hook enqueues provider control work.
    pub fn cancel(&self, reason: CancellationReason) -> bool {
        if self
            .inner
            .state
            .compare_exchange(
                CANCELLATION_ACTIVE,
                CANCELLATION_FIRED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return false;
        }
        self.inner.token.cancel();
        (self.inner.callback)(reason);
        true
    }

    /// Marks the request complete without cancelling its token or invoking the
    /// provider hook. Later response-body drops are then harmless because the
    /// provider has already reached a durable terminal.
    pub fn complete(&self) -> bool {
        self.inner
            .state
            .compare_exchange(
                CANCELLATION_ACTIVE,
                CANCELLATION_COMPLETED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    /// Returns a child-safe clone of the installed token.
    #[must_use]
    pub fn token(&self) -> CancellationToken {
        self.inner.token.clone()
    }

    /// Returns whether cancellation has fired.
    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.inner.state.load(Ordering::Acquire) == CANCELLATION_FIRED
            || self.inner.token.is_cancelled()
    }
}

/// Type-erased resource retained for the full response-receiver lifetime.
///
/// HTTP integration places an owned global semaphore permit here. The permit
/// cannot be released merely because headers were returned or the producer
/// finished; it remains held until the body receiver itself is dropped.
pub struct ResponseLifetimeGuard {
    _guard: Box<dyn Send + 'static>,
}

impl fmt::Debug for ResponseLifetimeGuard {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ResponseLifetimeGuard(..)")
    }
}

impl ResponseLifetimeGuard {
    /// Erases any owned, sendable lifetime resource.
    #[must_use]
    pub fn new<T: Send + 'static>(guard: T) -> Self {
        Self {
            _guard: Box::new(guard),
        }
    }
}

enum CloseState {
    Open,
    Finished,
    Failed(PipeCloseReason),
}

struct PipeState<T> {
    queue: VecDeque<T>,
    bytes: usize,
    close: CloseState,
    receiver_alive: bool,
}

impl<T> Default for PipeState<T> {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
            bytes: 0,
            close: CloseState::Open,
            receiver_alive: true,
        }
    }
}

struct PipeShared<T> {
    limits: BytePipeLimits,
    state: Mutex<PipeState<T>>,
    notify: Notify,
    cancellation: RequestCancellation,
}

impl<T> PipeShared<T> {
    fn lock(&self) -> std::sync::MutexGuard<'_, PipeState<T>> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn fail(&self, reason: PipeCloseReason) -> bool {
        let changed = {
            let mut state = self.lock();
            if matches!(state.close, CloseState::Open) {
                state.close = CloseState::Failed(reason);
                true
            } else {
                false
            }
        };
        if changed {
            self.cancellation.cancel(reason.cancellation_reason());
            self.notify.notify_waiters();
        }
        changed
    }
}

/// Sole nonblocking producer for a direct finite pipe.
pub struct BytePipeSender<T> {
    shared: Arc<PipeShared<T>>,
}

impl<T> fmt::Debug for BytePipeSender<T> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BytePipeSender")
            .field("stats", &self.stats())
            .finish()
    }
}

impl<T: PipeItem> BytePipeSender<T> {
    /// Publishes immediately or closes immediately on saturation.
    ///
    /// This method never waits for the receiver and never spawns a task.
    pub fn try_send(&self, item: T) -> Result<(), PipeError> {
        let bytes = item.pipe_bytes();
        let failure = {
            let mut state = self.shared.lock();
            match state.close {
                CloseState::Failed(reason) => return Err(PipeError::Closed(reason)),
                CloseState::Finished => {
                    return Err(PipeError::Closed(PipeCloseReason::ProducerDropped));
                }
                CloseState::Open => {}
            }
            if !state.receiver_alive {
                return Err(PipeError::Closed(PipeCloseReason::ConsumerDropped));
            }
            if state.queue.len() >= self.shared.limits.maximum_items {
                state.close = CloseState::Failed(PipeCloseReason::ItemOverflow);
                Some((
                    PipeError::ItemOverflow,
                    PipeCloseReason::ItemOverflow.cancellation_reason(),
                ))
            } else if bytes > self.shared.limits.maximum_bytes.saturating_sub(state.bytes) {
                state.close = CloseState::Failed(PipeCloseReason::ByteOverflow);
                Some((
                    PipeError::ByteOverflow,
                    PipeCloseReason::ByteOverflow.cancellation_reason(),
                ))
            } else {
                state.bytes += bytes;
                state.queue.push_back(item);
                None
            }
        };

        if let Some((error, cancellation)) = failure {
            self.shared.cancellation.cancel(cancellation);
            self.shared.notify.notify_waiters();
            Err(error)
        } else {
            self.shared.notify.notify_one();
            Ok(())
        }
    }
}

impl<T> BytePipeSender<T> {
    /// Gracefully closes the producer side. Every accepted item remains
    /// drainable before the receiver observes EOF.
    pub fn finish(&self) {
        let changed = {
            let mut state = self.shared.lock();
            if matches!(state.close, CloseState::Open) {
                state.close = CloseState::Finished;
                true
            } else {
                false
            }
        };
        if changed {
            self.shared.notify.notify_waiters();
        }
    }

    /// Closes with an observable reason and cancels the request exactly once.
    pub fn close(&self, reason: PipeCloseReason) {
        self.shared.fail(reason);
    }

    /// Returns exact current occupancy.
    #[must_use]
    pub fn stats(&self) -> BytePipeStats {
        let state = self.shared.lock();
        BytePipeStats {
            queued_items: state.queue.len(),
            queued_bytes: state.bytes,
            close_reason: match state.close {
                CloseState::Failed(reason) => Some(reason),
                CloseState::Open | CloseState::Finished => None,
            },
            is_closed: !matches!(state.close, CloseState::Open),
        }
    }
}

impl<T> Drop for BytePipeSender<T> {
    fn drop(&mut self) {
        self.shared.fail(PipeCloseReason::ProducerDropped);
    }
}

/// Sole response/body consumer for a direct finite pipe.
pub struct BytePipeReceiver<T> {
    shared: Arc<PipeShared<T>>,
    _response_budget: Option<ResponseLifetimeGuard>,
}

impl<T> fmt::Debug for BytePipeReceiver<T> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BytePipeReceiver")
            .field("stats", &self.stats())
            .finish_non_exhaustive()
    }
}

impl<T: PipeItem> BytePipeReceiver<T> {
    /// Receives the next accepted item, graceful EOF, or the close reason.
    ///
    /// Items accepted before a failure are returned before the failure. This
    /// makes overload observable without silently discarding accepted output.
    pub async fn recv(&mut self) -> Result<Option<T>, PipeError> {
        loop {
            let notified = self.shared.notify.notified();
            {
                let mut state = self.shared.lock();
                if let Some(item) = state.queue.pop_front() {
                    state.bytes = state.bytes.saturating_sub(item.pipe_bytes());
                    return Ok(Some(item));
                }
                match state.close {
                    CloseState::Open => {}
                    CloseState::Finished => return Ok(None),
                    CloseState::Failed(reason) => return Err(PipeError::Closed(reason)),
                }
            }
            notified.await;
        }
    }
}

impl<T> BytePipeReceiver<T> {
    /// Returns exact current occupancy.
    #[must_use]
    pub fn stats(&self) -> BytePipeStats {
        let state = self.shared.lock();
        BytePipeStats {
            queued_items: state.queue.len(),
            queued_bytes: state.bytes,
            close_reason: match state.close {
                CloseState::Failed(reason) => Some(reason),
                CloseState::Open | CloseState::Finished => None,
            },
            is_closed: !matches!(state.close, CloseState::Open),
        }
    }
}

impl<T> Drop for BytePipeReceiver<T> {
    fn drop(&mut self) {
        let should_cancel = {
            let mut state = self.shared.lock();
            state.receiver_alive = false;
            match state.close {
                CloseState::Finished if state.queue.is_empty() => false,
                CloseState::Failed(_) => false,
                CloseState::Open | CloseState::Finished => {
                    state.close = CloseState::Failed(PipeCloseReason::ConsumerDropped);
                    true
                }
            }
        };
        if should_cancel {
            self.shared
                .cancellation
                .cancel(CancellationReason::ConsumerDropped);
            self.shared.notify.notify_waiters();
        }
    }
}

/// Creates one direct item-and-byte bounded pipe.
pub fn byte_pipe<T>(
    limits: BytePipeLimits,
    cancellation: RequestCancellation,
    response_budget: Option<ResponseLifetimeGuard>,
) -> Result<(BytePipeSender<T>, BytePipeReceiver<T>), PipeConfigError> {
    let limits = limits.validate()?;
    let shared = Arc::new(PipeShared {
        limits,
        state: Mutex::new(PipeState::default()),
        notify: Notify::new(),
        cancellation,
    });
    Ok((
        BytePipeSender {
            shared: shared.clone(),
        },
        BytePipeReceiver {
            shared,
            _response_budget: response_budget,
        },
    ))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;

    use tokio::sync::Semaphore;

    use super::*;

    fn cancellation_counter() -> (RequestCancellation, Arc<AtomicUsize>) {
        let count = Arc::new(AtomicUsize::new(0));
        let observed = count.clone();
        (
            RequestCancellation::new(CancellationToken::new(), move |_| {
                observed.fetch_add(1, Ordering::AcqRel);
            }),
            count,
        )
    }

    #[tokio::test]
    async fn slow_consumer_closes_without_blocking_or_dropping_accepted_items() {
        let (cancellation, count) = cancellation_counter();
        let (sender, mut receiver) = byte_pipe(
            BytePipeLimits {
                maximum_items: 2,
                maximum_bytes: 4,
            },
            cancellation,
            None,
        )
        .expect("pipe");

        sender.try_send(vec![1, 2]).expect("first");
        sender.try_send(vec![3, 4]).expect("second");
        assert_eq!(sender.try_send(vec![5]), Err(PipeError::ItemOverflow));
        assert_eq!(count.load(Ordering::Acquire), 1);
        assert_eq!(receiver.recv().await.expect("accepted"), Some(vec![1, 2]));
        assert_eq!(receiver.recv().await.expect("accepted"), Some(vec![3, 4]));
        assert_eq!(
            receiver.recv().await,
            Err(PipeError::Closed(PipeCloseReason::ItemOverflow))
        );
        sender.close(PipeCloseReason::Cancelled);
        assert_eq!(count.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn byte_bound_is_independent_from_item_bound() {
        let (cancellation, count) = cancellation_counter();
        let (sender, mut receiver) = byte_pipe(
            BytePipeLimits {
                maximum_items: 3,
                maximum_bytes: 4,
            },
            cancellation,
            None,
        )
        .expect("pipe");
        sender.try_send(vec![1, 2, 3, 4]).expect("exact bound");
        assert_eq!(sender.try_send(vec![5]), Err(PipeError::ByteOverflow));
        assert_eq!(count.load(Ordering::Acquire), 1);
        assert_eq!(
            receiver.recv().await.expect("accepted"),
            Some(vec![1, 2, 3, 4])
        );
        assert_eq!(
            receiver.recv().await,
            Err(PipeError::Closed(PipeCloseReason::ByteOverflow))
        );
    }

    #[tokio::test]
    async fn body_drop_cancels_exactly_once() {
        let (cancellation, count) = cancellation_counter();
        let (sender, receiver) = byte_pipe::<Vec<u8>>(
            BytePipeLimits {
                maximum_items: 1,
                maximum_bytes: 1,
            },
            cancellation.clone(),
            None,
        )
        .expect("pipe");
        drop(receiver);
        cancellation.cancel(CancellationReason::ClientCancelled);
        drop(sender);
        assert_eq!(count.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn response_guard_lives_until_receiver_drop() {
        let semaphore = Arc::new(Semaphore::new(1));
        let permit = semaphore
            .clone()
            .acquire_owned()
            .await
            .expect("budget permit");
        let (sender, receiver) = byte_pipe::<Vec<u8>>(
            BytePipeLimits {
                maximum_items: 1,
                maximum_bytes: 1,
            },
            RequestCancellation::token_only(CancellationToken::new()),
            Some(ResponseLifetimeGuard::new(permit)),
        )
        .expect("pipe");
        sender.finish();
        drop(sender);
        assert!(semaphore.clone().try_acquire_owned().is_err());
        drop(receiver);
        assert!(semaphore.try_acquire_owned().is_ok());
    }

    #[tokio::test]
    async fn receiver_can_drain_ten_times_total_capacity_without_growth() {
        let (sender, mut receiver) = byte_pipe(
            BytePipeLimits {
                maximum_items: 2,
                maximum_bytes: 8,
            },
            RequestCancellation::token_only(CancellationToken::new()),
            None,
        )
        .expect("pipe");
        for value in 0_u8..20 {
            sender.try_send(vec![value; 4]).expect("bounded send");
            assert_eq!(
                receiver.recv().await.expect("receive"),
                Some(vec![value; 4])
            );
            assert_eq!(sender.stats().queued_bytes, 0);
        }
        sender.finish();
        assert_eq!(receiver.recv().await.expect("EOF"), None);
    }

    #[tokio::test]
    async fn deterministic_operation_traces_conserve_items_and_bytes() {
        for seed in 1_u64..64 {
            let (sender, mut receiver) = byte_pipe(
                BytePipeLimits {
                    maximum_items: 4,
                    maximum_bytes: 12,
                },
                RequestCancellation::token_only(CancellationToken::new()),
                None,
            )
            .expect("pipe");
            let mut state = seed;
            let mut accepted = VecDeque::new();
            for _ in 0..100 {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1);
                if state & 1 == 0 && !sender.stats().is_closed {
                    let item = vec![state as u8; (state as usize % 5) + 1];
                    if sender.try_send(item.clone()).is_ok() {
                        accepted.push_back(item);
                    }
                } else if let Some(expected) = accepted.pop_front() {
                    assert_eq!(
                        receiver.recv().await.expect("accepted item"),
                        Some(expected)
                    );
                }
                let stats = sender.stats();
                assert!(stats.queued_items <= 4);
                assert!(stats.queued_bytes <= 12);
                assert_eq!(stats.queued_items, accepted.len());
                assert_eq!(
                    stats.queued_bytes,
                    accepted.iter().map(Vec::len).sum::<usize>()
                );
            }
            drop(receiver);
        }
    }
}
