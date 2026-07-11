use std::{
    collections::BTreeSet,
    future::Future,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    task::Poll,
    time::Duration,
};

use thiserror::Error;
use tokio::{
    sync::{mpsc, watch},
    task::{JoinError, JoinSet},
    time::{Instant, sleep_until},
};
use tokio_util::sync::CancellationToken;

/// Startup, shutdown, and task ownership bounds.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SupervisorConfig {
    /// Common deadline for every essential task to report ready.
    pub startup_timeout: Duration,
    /// Common deadline for all essential tasks to stop after cancellation.
    pub shutdown_timeout: Duration,
    /// Maximum number of tasks the supervisor may own.
    pub maximum_tasks: usize,
}

impl Default for SupervisorConfig {
    fn default() -> Self {
        Self {
            startup_timeout: Duration::from_secs(30),
            shutdown_timeout: Duration::from_secs(20),
            maximum_tasks: 64,
        }
    }
}

impl SupervisorConfig {
    fn validate(self) -> Result<Self, SupervisorConfigError> {
        if self.startup_timeout.is_zero() {
            return Err(SupervisorConfigError::InvalidStartupTimeout);
        }
        if self.shutdown_timeout.is_zero() {
            return Err(SupervisorConfigError::InvalidShutdownTimeout);
        }
        if self.maximum_tasks == 0 {
            return Err(SupervisorConfigError::NoTaskCapacity);
        }
        Ok(self)
    }
}

/// Invalid supervisor bound.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SupervisorConfigError {
    /// Startup must have a finite opportunity to complete.
    #[error("supervisor startup timeout must be greater than zero")]
    InvalidStartupTimeout,
    /// Shutdown must have a finite opportunity to complete.
    #[error("supervisor shutdown timeout must be greater than zero")]
    InvalidShutdownTimeout,
    /// The supervisor must be able to own at least one task.
    #[error("supervisor maximum task count must be greater than zero")]
    NoTaskCapacity,
}

/// Concrete error returned by an essential task.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{message}")]
pub struct EssentialTaskError {
    message: Arc<str>,
}

impl EssentialTaskError {
    /// Creates a task failure while preserving a stable readiness-safe message.
    #[must_use]
    pub fn new(message: impl Into<Arc<str>>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Returns the task-provided error text.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

/// Essential task startup context.
#[derive(Clone)]
pub struct EssentialTaskContext {
    name: Arc<str>,
    cancellation: CancellationToken,
    ready_tx: mpsc::Sender<Arc<str>>,
    ready: Arc<AtomicBool>,
}

impl EssentialTaskContext {
    /// Returns coordinated process cancellation.
    #[must_use]
    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancellation.clone()
    }

    /// Reports successful startup exactly once.
    pub fn mark_ready(&self) -> Result<(), TaskReadyError> {
        if self.ready.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.ready_tx
            .try_send(self.name.clone())
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => TaskReadyError::SignalQueueFull,
                mpsc::error::TrySendError::Closed(_) => TaskReadyError::SupervisorUnavailable,
            })
    }
}

/// Failure to publish one task's startup completion.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum TaskReadyError {
    /// This indicates a supervisor accounting invariant violation.
    #[error("supervisor readiness signal queue is full")]
    SignalQueueFull,
    /// The supervisor has already terminated.
    #[error("supervisor is unavailable")]
    SupervisorUnavailable,
}

/// Readiness state visible to the HTTP composition root.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SupervisorStatus {
    /// Essential tasks are starting.
    Starting,
    /// Every essential task reported ready and remains alive.
    Ready,
    /// Coordinated shutdown is in progress.
    Stopping,
    /// An essential task failed or exited unexpectedly.
    Fatal,
    /// Coordinated shutdown completed.
    Stopped,
}

impl SupervisorStatus {
    const fn as_u8(self) -> u8 {
        match self {
            Self::Starting => 0,
            Self::Ready => 1,
            Self::Stopping => 2,
            Self::Fatal => 3,
            Self::Stopped => 4,
        }
    }

    const fn from_u8(value: u8) -> Self {
        match value {
            0 => Self::Starting,
            1 => Self::Ready,
            2 => Self::Stopping,
            3 => Self::Fatal,
            4 => Self::Stopped,
            _ => Self::Fatal,
        }
    }
}

/// Latest-value supervisor readiness report.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SupervisorReadiness {
    /// Current supervisor lifecycle state.
    pub status: SupervisorStatus,
    /// Stable fatal reason, if one occurred.
    pub failure: Option<Arc<str>>,
}

impl SupervisorReadiness {
    /// Returns true only while all essential tasks are ready and alive.
    #[must_use]
    pub const fn is_ready(&self) -> bool {
        matches!(self.status, SupervisorStatus::Ready)
    }
}

/// Cloneable shutdown and readiness handle.
#[derive(Clone)]
pub struct SupervisorHandle {
    cancellation: CancellationToken,
    status: Arc<AtomicU8>,
    readiness_rx: watch::Receiver<SupervisorReadiness>,
}

impl SupervisorHandle {
    /// Starts coordinated cancellation.
    pub fn shutdown(&self) {
        self.cancellation.cancel();
    }

    /// Returns true only while all essential tasks remain healthy.
    #[must_use]
    pub fn is_ready(&self) -> bool {
        SupervisorStatus::from_u8(self.status.load(Ordering::Acquire)) == SupervisorStatus::Ready
    }

    /// Returns the immutable latest readiness state.
    #[must_use]
    pub fn readiness(&self) -> SupervisorReadiness {
        self.readiness_rx.borrow().clone()
    }

    /// Waits for the next readiness state change.
    pub async fn changed(&mut self) -> Result<SupervisorReadiness, SupervisorUnavailable> {
        self.readiness_rx
            .changed()
            .await
            .map_err(|_| SupervisorUnavailable)?;
        Ok(self.readiness())
    }
}

/// The owning supervisor exited.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("supervisor is unavailable")]
pub struct SupervisorUnavailable;

/// Failure to register an essential task.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum SpawnEssentialError {
    /// Task names are stable nonempty readiness identifiers.
    #[error("essential task name must not be empty")]
    EmptyName,
    /// A task name identifies exactly one owned future.
    #[error("essential task {0} is already registered")]
    DuplicateName(Arc<str>),
    /// The configured ownership bound was reached.
    #[error("supervisor task limit of {maximum} reached")]
    TaskLimit {
        /// Configured task bound.
        maximum: usize,
    },
}

enum TaskCompletion {
    Succeeded,
    Failed(EssentialTaskError),
    Panicked(Arc<str>),
}

struct TaskExit {
    name: Arc<str>,
    completion: TaskCompletion,
}

enum ShutdownFailure {
    Failed {
        name: Arc<str>,
        error: EssentialTaskError,
    },
    Panicked {
        name: Arc<str>,
        message: Arc<str>,
    },
    Join(Arc<str>),
}

struct ShutdownOutcome {
    timed_out: bool,
    failure: Option<ShutdownFailure>,
}

/// Essential task supervision failure.
#[derive(Clone, Debug, Error, PartialEq)]
pub enum SupervisorError {
    /// `run` requires at least one essential task.
    #[error("supervisor has no essential tasks")]
    NoEssentialTasks,
    /// Not every task reported ready before the startup bound.
    #[error("essential task startup exceeded {timeout:?}; shutdown_timed_out={shutdown_timed_out}")]
    StartupTimeout {
        /// Configured startup bound.
        timeout: Duration,
        /// Whether cancellation also exceeded its bound.
        shutdown_timed_out: bool,
    },
    /// A task returned success without coordinated cancellation.
    #[error("essential task {name} exited unexpectedly; shutdown_timed_out={shutdown_timed_out}")]
    UnexpectedExit {
        /// Exited task.
        name: Arc<str>,
        /// Whether cancellation also exceeded its bound.
        shutdown_timed_out: bool,
    },
    /// A task returned an explicit error.
    #[error("essential task {name} failed: {source}; shutdown_timed_out={shutdown_timed_out}")]
    EssentialFailed {
        /// Failed task.
        name: Arc<str>,
        /// Task-provided failure.
        source: EssentialTaskError,
        /// Whether cancellation also exceeded its bound.
        shutdown_timed_out: bool,
    },
    /// A panic was captured at the essential-task boundary.
    #[error("essential task {name} panicked: {message}; shutdown_timed_out={shutdown_timed_out}")]
    EssentialPanicked {
        /// Panicked task.
        name: Arc<str>,
        /// Panic payload, when textual.
        message: Arc<str>,
        /// Whether cancellation also exceeded its bound.
        shutdown_timed_out: bool,
    },
    /// A Tokio task wrapper failed independently of its owned future.
    #[error("essential task join failed: {message}; shutdown_timed_out={shutdown_timed_out}")]
    Join {
        /// Tokio join failure.
        message: Arc<str>,
        /// Whether cancellation also exceeded its bound.
        shutdown_timed_out: bool,
    },
    /// Coordinated shutdown exceeded its finite bound.
    #[error("essential task shutdown exceeded {0:?}")]
    ShutdownTimeout(Duration),
}

/// Sole owner of all essential task futures.
pub struct Supervisor {
    config: SupervisorConfig,
    cancellation: CancellationToken,
    status: Arc<AtomicU8>,
    readiness_tx: watch::Sender<SupervisorReadiness>,
    ready_tx: mpsc::Sender<Arc<str>>,
    ready_rx: mpsc::Receiver<Arc<str>>,
    task_names: BTreeSet<Arc<str>>,
    tasks: JoinSet<TaskExit>,
}

impl Supervisor {
    /// Creates a supervisor and its readiness/shutdown handle.
    pub fn new(
        config: SupervisorConfig,
    ) -> Result<(Self, SupervisorHandle), SupervisorConfigError> {
        let config = config.validate()?;
        let cancellation = CancellationToken::new();
        let status = Arc::new(AtomicU8::new(SupervisorStatus::Starting.as_u8()));
        let initial = SupervisorReadiness {
            status: SupervisorStatus::Starting,
            failure: None,
        };
        let (readiness_tx, readiness_rx) = watch::channel(initial);
        let (ready_tx, ready_rx) = mpsc::channel(config.maximum_tasks);
        let handle = SupervisorHandle {
            cancellation: cancellation.clone(),
            status: status.clone(),
            readiness_rx,
        };
        Ok((
            Self {
                config,
                cancellation,
                status,
                readiness_tx,
                ready_tx,
                ready_rx,
                task_names: BTreeSet::new(),
                tasks: JoinSet::new(),
            },
            handle,
        ))
    }

    /// Registers and starts one named essential future.
    ///
    /// The future is owned by the supervisor's `JoinSet`; dropping or timing
    /// out the supervisor aborts it rather than detaching it.
    pub fn spawn_essential<F, Fut>(
        &mut self,
        name: impl Into<Arc<str>>,
        task: F,
    ) -> Result<(), SpawnEssentialError>
    where
        F: FnOnce(EssentialTaskContext) -> Fut + Send + 'static,
        Fut: Future<Output = Result<(), EssentialTaskError>> + Send + 'static,
    {
        let name = name.into();
        if name.trim().is_empty() {
            return Err(SpawnEssentialError::EmptyName);
        }
        if self.task_names.contains(&name) {
            return Err(SpawnEssentialError::DuplicateName(name));
        }
        if self.task_names.len() >= self.config.maximum_tasks {
            return Err(SpawnEssentialError::TaskLimit {
                maximum: self.config.maximum_tasks,
            });
        }
        self.task_names.insert(name.clone());
        let context = EssentialTaskContext {
            name: name.clone(),
            cancellation: self.cancellation.child_token(),
            ready_tx: self.ready_tx.clone(),
            ready: Arc::new(AtomicBool::new(false)),
        };
        self.tasks.spawn(async move {
            let completion = match catch_task_panic(task(context)).await {
                Ok(Ok(())) => TaskCompletion::Succeeded,
                Ok(Err(error)) => TaskCompletion::Failed(error),
                Err(payload) => TaskCompletion::Panicked(panic_message(payload)),
            };
            TaskExit { name, completion }
        });
        Ok(())
    }

    /// Waits for startup, supervises every task, and owns bounded shutdown.
    pub async fn run(mut self) -> Result<(), SupervisorError> {
        if self.task_names.is_empty() {
            self.set_fatal("supervisor has no essential tasks");
            return Err(SupervisorError::NoEssentialTasks);
        }
        let startup_deadline = Instant::now() + self.config.startup_timeout;
        let mut ready = BTreeSet::new();
        while ready.len() != self.task_names.len() {
            tokio::select! {
                biased;
                () = self.cancellation.cancelled() => {
                    return self.finish_shutdown().await;
                }
                exit = self.tasks.join_next() => {
                    let error = self.unexpected_exit(exit, false).await;
                    return Err(error);
                }
                signal = self.ready_rx.recv() => {
                    if let Some(name) = signal
                        && self.task_names.contains(&name)
                    {
                        ready.insert(name);
                    }
                }
                () = sleep_until(startup_deadline) => {
                    self.set_fatal(format!(
                        "essential task startup exceeded {:?}",
                        self.config.startup_timeout
                    ));
                    self.cancellation.cancel();
                    let shutdown = self.drain_shutdown().await;
                    return Err(SupervisorError::StartupTimeout {
                        timeout: self.config.startup_timeout,
                        shutdown_timed_out: shutdown.timed_out,
                    });
                }
            }
        }

        self.set_status(SupervisorStatus::Ready, None);
        tokio::select! {
            biased;
            () = self.cancellation.cancelled() => self.finish_shutdown().await,
            exit = self.tasks.join_next() => {
                Err(self.unexpected_exit(exit, true).await)
            }
        }
    }

    async fn unexpected_exit(
        &mut self,
        exit: Option<Result<TaskExit, JoinError>>,
        _was_ready: bool,
    ) -> SupervisorError {
        let primary = match exit {
            Some(Ok(TaskExit {
                name,
                completion: TaskCompletion::Succeeded,
            })) => PrimaryFailure::UnexpectedExit { name },
            Some(Ok(TaskExit {
                name,
                completion: TaskCompletion::Failed(error),
            })) => PrimaryFailure::Failed { name, error },
            Some(Ok(TaskExit {
                name,
                completion: TaskCompletion::Panicked(message),
            })) => PrimaryFailure::Panicked { name, message },
            Some(Err(error)) => PrimaryFailure::Join(Arc::from(error.to_string())),
            None => PrimaryFailure::Join(Arc::from("essential task set became empty")),
        };
        self.set_fatal(primary.message());
        self.cancellation.cancel();
        let shutdown = self.drain_shutdown().await;
        primary.into_error(shutdown.timed_out)
    }

    async fn finish_shutdown(&mut self) -> Result<(), SupervisorError> {
        self.set_status(SupervisorStatus::Stopping, None);
        self.cancellation.cancel();
        let outcome = self.drain_shutdown().await;
        if outcome.timed_out {
            self.set_fatal(format!(
                "essential task shutdown exceeded {:?}",
                self.config.shutdown_timeout
            ));
            return Err(SupervisorError::ShutdownTimeout(
                self.config.shutdown_timeout,
            ));
        }
        if let Some(failure) = outcome.failure {
            let error = shutdown_failure_error(failure);
            self.set_fatal(error.to_string());
            return Err(error);
        }
        self.set_status(SupervisorStatus::Stopped, None);
        Ok(())
    }

    async fn drain_shutdown(&mut self) -> ShutdownOutcome {
        let deadline = Instant::now() + self.config.shutdown_timeout;
        let mut failure = None;
        while !self.tasks.is_empty() {
            tokio::select! {
                biased;
                exit = self.tasks.join_next() => {
                    if failure.is_none() {
                        failure = classify_shutdown_exit(exit);
                    }
                }
                () = sleep_until(deadline) => {
                    self.tasks.abort_all();
                    while self.tasks.join_next().await.is_some() {}
                    return ShutdownOutcome {
                        timed_out: true,
                        failure,
                    };
                }
            }
        }
        ShutdownOutcome {
            timed_out: false,
            failure,
        }
    }

    fn set_fatal(&self, failure: impl Into<Arc<str>>) {
        self.set_status(SupervisorStatus::Fatal, Some(failure.into()));
    }

    fn set_status(&self, status: SupervisorStatus, failure: Option<Arc<str>>) {
        self.status.store(status.as_u8(), Ordering::Release);
        self.readiness_tx
            .send_replace(SupervisorReadiness { status, failure });
    }
}

async fn catch_task_panic<F>(future: F) -> Result<F::Output, Box<dyn std::any::Any + Send>>
where
    F: Future,
{
    let mut future = Box::pin(future);
    std::future::poll_fn(|context| {
        match catch_unwind(AssertUnwindSafe(|| future.as_mut().poll(context))) {
            Ok(Poll::Ready(output)) => Poll::Ready(Ok(output)),
            Ok(Poll::Pending) => Poll::Pending,
            Err(payload) => Poll::Ready(Err(payload)),
        }
    })
    .await
}

enum PrimaryFailure {
    UnexpectedExit {
        name: Arc<str>,
    },
    Failed {
        name: Arc<str>,
        error: EssentialTaskError,
    },
    Panicked {
        name: Arc<str>,
        message: Arc<str>,
    },
    Join(Arc<str>),
}

impl PrimaryFailure {
    fn message(&self) -> Arc<str> {
        match self {
            Self::UnexpectedExit { name } => {
                Arc::from(format!("essential task {name} exited unexpectedly"))
            }
            Self::Failed { name, error } => {
                Arc::from(format!("essential task {name} failed: {error}"))
            }
            Self::Panicked { name, message } => {
                Arc::from(format!("essential task {name} panicked: {message}"))
            }
            Self::Join(message) => Arc::from(format!("essential task join failed: {message}")),
        }
    }

    fn into_error(self, shutdown_timed_out: bool) -> SupervisorError {
        match self {
            Self::UnexpectedExit { name } => SupervisorError::UnexpectedExit {
                name,
                shutdown_timed_out,
            },
            Self::Failed { name, error } => SupervisorError::EssentialFailed {
                name,
                source: error,
                shutdown_timed_out,
            },
            Self::Panicked { name, message } => SupervisorError::EssentialPanicked {
                name,
                message,
                shutdown_timed_out,
            },
            Self::Join(message) => SupervisorError::Join {
                message,
                shutdown_timed_out,
            },
        }
    }
}

fn classify_shutdown_exit(exit: Option<Result<TaskExit, JoinError>>) -> Option<ShutdownFailure> {
    match exit {
        Some(Ok(TaskExit {
            completion: TaskCompletion::Succeeded,
            ..
        }))
        | None => None,
        Some(Ok(TaskExit {
            name,
            completion: TaskCompletion::Failed(error),
        })) => Some(ShutdownFailure::Failed { name, error }),
        Some(Ok(TaskExit {
            name,
            completion: TaskCompletion::Panicked(message),
        })) => Some(ShutdownFailure::Panicked { name, message }),
        Some(Err(error)) if error.is_cancelled() => None,
        Some(Err(error)) => Some(ShutdownFailure::Join(Arc::from(error.to_string()))),
    }
}

fn shutdown_failure_error(failure: ShutdownFailure) -> SupervisorError {
    match failure {
        ShutdownFailure::Failed { name, error } => SupervisorError::EssentialFailed {
            name,
            source: error,
            shutdown_timed_out: false,
        },
        ShutdownFailure::Panicked { name, message } => SupervisorError::EssentialPanicked {
            name,
            message,
            shutdown_timed_out: false,
        },
        ShutdownFailure::Join(message) => SupervisorError::Join {
            message,
            shutdown_timed_out: false,
        },
    }
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> Arc<str> {
    if let Some(message) = payload.downcast_ref::<&str>() {
        Arc::from(*message)
    } else if let Some(message) = payload.downcast_ref::<String>() {
        Arc::from(message.as_str())
    } else {
        Arc::from("non-string panic payload")
    }
}

#[cfg(test)]
mod tests {
    use std::{future::pending, time::Duration};

    use super::{
        EssentialTaskError, Supervisor, SupervisorConfig, SupervisorError, SupervisorStatus,
    };

    fn config() -> SupervisorConfig {
        SupervisorConfig {
            startup_timeout: Duration::from_millis(100),
            shutdown_timeout: Duration::from_millis(30),
            maximum_tasks: 4,
        }
    }

    #[tokio::test]
    async fn panic_is_fatal_and_readiness_visible() {
        let (mut supervisor, mut handle) = Supervisor::new(config()).expect("valid config");
        supervisor
            .spawn_essential("panic", |context| async move {
                context.mark_ready().expect("ready");
                panic!("essential boom");
                #[allow(unreachable_code)]
                Ok(())
            })
            .expect("spawn");

        let result = supervisor.run().await;
        assert!(matches!(
            result,
            Err(SupervisorError::EssentialPanicked { .. })
        ));
        while handle.readiness().status != SupervisorStatus::Fatal {
            handle.changed().await.expect("readiness update");
        }
        assert!(!handle.is_ready());
        assert!(
            handle
                .readiness()
                .failure
                .as_deref()
                .is_some_and(|failure| failure.contains("essential boom"))
        );
    }

    #[tokio::test]
    async fn shutdown_is_bounded_and_aborts_owned_task() {
        let (mut supervisor, handle) = Supervisor::new(config()).expect("valid config");
        supervisor
            .spawn_essential("ignores-cancel", |context| async move {
                context.mark_ready().expect("ready");
                pending::<()>().await;
                Ok(())
            })
            .expect("spawn");
        handle.shutdown();
        assert_eq!(
            supervisor.run().await,
            Err(SupervisorError::ShutdownTimeout(config().shutdown_timeout))
        );
    }

    #[tokio::test]
    async fn startup_is_bounded_and_cancels_owned_task() {
        let mut bounded = config();
        bounded.startup_timeout = Duration::from_millis(10);
        let (mut supervisor, _handle) = Supervisor::new(bounded).expect("valid config");
        supervisor
            .spawn_essential("never-ready", |context| async move {
                context.cancellation_token().cancelled().await;
                Ok(())
            })
            .expect("spawn");
        assert_eq!(
            supervisor.run().await,
            Err(SupervisorError::StartupTimeout {
                timeout: bounded.startup_timeout,
                shutdown_timed_out: false,
            })
        );
    }

    #[tokio::test]
    async fn task_error_is_propagated() {
        let (mut supervisor, _handle) = Supervisor::new(config()).expect("valid config");
        supervisor
            .spawn_essential("fails", |context| async move {
                context.mark_ready().expect("ready");
                Err(EssentialTaskError::new("fleet failed"))
            })
            .expect("spawn");
        assert!(matches!(
            supervisor.run().await,
            Err(SupervisorError::EssentialFailed { source, .. })
                if source.message() == "fleet failed"
        ));
    }
}
