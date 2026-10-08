use super::{PlanError, Planner, Readiness};
use crate::api::{Endpoint, PlanRequest};
use crate::contract::{
    ContractMetadata, ContractVersions, METADATA_FILE, PromptArtifact, compute_contract_id,
};
use crate::preload::PreloadError;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex as StdMutex, mpsc};
use std::time::Duration;
use tempfile::TempDir;
use tokio::sync::oneshot;
use tokio::task::{JoinError, JoinHandle};

const WAIT: Duration = Duration::from_secs(5);
const HELD_WINDOW: Duration = Duration::from_millis(100);

// Per-Planner, one-shot instrumentation. No global hooks or hook lock survives
// an await/block/panic. Normal non-test builds contain neither hooks nor calls.
#[derive(Default)]
pub(super) struct Hooks {
    plan_permit: StdMutex<Option<AsyncPause>>,
    plan_load: StdMutex<Option<BlockingHook>>,
    preload_load: StdMutex<Option<BlockingHook>>,
    preload_waiting: StdMutex<Option<oneshot::Sender<()>>>,
    plan_loads: AtomicUsize,
    preload_loads: AtomicUsize,
}

struct AsyncPause {
    id: String,
    entered: oneshot::Sender<()>,
    release: oneshot::Receiver<()>,
}

struct BlockingHook {
    id: String,
    action: BlockingAction,
}

enum BlockingAction {
    Pause(oneshot::Sender<()>, mpsc::Receiver<()>),
    Panic,
}

enum Release {
    Async(oneshot::Sender<()>),
    Blocking(mpsc::Sender<()>),
}

struct PauseControl {
    entered: oneshot::Receiver<()>,
    release: Option<Release>,
}

impl PauseControl {
    async fn entered(&mut self) {
        bounded(&mut self.entered)
            .await
            .expect("hook sender disappeared");
    }

    async fn still_blocked(&mut self) {
        assert!(
            tokio::time::timeout(HELD_WINDOW, &mut self.entered)
                .await
                .is_err(),
            "preload loader ran while a real plan still owned a worker permit"
        );
    }

    fn release(&mut self) {
        match self.release.take() {
            Some(Release::Async(sender)) => {
                let _ = sender.send(());
            }
            Some(Release::Blocking(sender)) => {
                let _ = sender.send(());
            }
            None => {}
        }
    }
}

impl Drop for PauseControl {
    fn drop(&mut self) {
        self.release();
    }
}

impl Hooks {
    fn pause_plan_permit(&self, id: &str) -> PauseControl {
        let (entered, observed) = oneshot::channel();
        let (release, resumed) = oneshot::channel();
        let mut slot = self.plan_permit.lock().unwrap();
        assert!(slot.is_none());
        *slot = Some(AsyncPause {
            id: id.into(),
            entered,
            release: resumed,
        });
        PauseControl {
            entered: observed,
            release: Some(Release::Async(release)),
        }
    }

    fn pause_blocking(slot: &StdMutex<Option<BlockingHook>>, id: &str) -> PauseControl {
        let (entered, observed) = oneshot::channel();
        let (release, resumed) = mpsc::channel();
        let mut slot = slot.lock().unwrap();
        assert!(slot.is_none());
        *slot = Some(BlockingHook {
            id: id.into(),
            action: BlockingAction::Pause(entered, resumed),
        });
        PauseControl {
            entered: observed,
            release: Some(Release::Blocking(release)),
        }
    }

    fn preload_started(&self) -> oneshot::Receiver<()> {
        let (sender, receiver) = oneshot::channel();
        let mut slot = self.preload_waiting.lock().unwrap();
        assert!(slot.is_none());
        *slot = Some(sender);
        receiver
    }

    pub(super) async fn before_plan_permit(&self, id: &str) {
        let hook = {
            let mut slot = self.plan_permit.lock().unwrap();
            if slot.as_ref().is_some_and(|hook| hook.id == id) {
                slot.take()
            } else {
                None
            }
        };
        if let Some(hook) = hook {
            let _ = hook.entered.send(());
            let _ = bounded(hook.release).await;
        }
    }

    fn blocking(slot: &StdMutex<Option<BlockingHook>>, id: &str) {
        let hook = {
            let mut slot = slot.lock().unwrap();
            if slot.as_ref().is_some_and(|hook| hook.id == id) {
                slot.take()
            } else {
                None
            }
        };
        match hook.map(|hook| hook.action) {
            Some(BlockingAction::Pause(entered, release)) => {
                let _ = entered.send(());
                match release.recv_timeout(WAIT) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {}
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        panic!("blocking test hook was not released")
                    }
                }
            }
            Some(BlockingAction::Panic) => panic!("injected preload worker panic"),
            None => {}
        }
    }

    pub(super) fn before_plan_load(&self, id: &str) {
        self.plan_loads.fetch_add(1, Ordering::SeqCst);
        Self::blocking(&self.plan_load, id);
    }

    pub(super) fn before_preload_permits(&self) {
        let notify = { self.preload_waiting.lock().unwrap().take() };
        if let Some(sender) = notify {
            let _ = sender.send(());
        }
    }

    pub(super) fn before_preload_load(&self, id: &str) {
        self.preload_loads.fetch_add(1, Ordering::SeqCst);
        Self::blocking(&self.preload_load, id);
    }
}

// Aborting the async owner cannot stop an already-running blocking loader. Its
// separate PauseControl always releases on unwind; recv_timeout is the fallback.
struct OwnedTask<T>(Option<JoinHandle<T>>);

impl<T: Send + 'static> OwnedTask<T> {
    fn spawn(future: impl Future<Output = T> + Send + 'static) -> Self {
        Self(Some(tokio::spawn(future)))
    }

    fn abort(&self) {
        self.0.as_ref().unwrap().abort();
    }

    async fn join(mut self) -> Result<T, JoinError> {
        let result = bounded(self.0.as_mut().unwrap()).await;
        self.0.take();
        result
    }
}

impl<T> Drop for OwnedTask<T> {
    fn drop(&mut self) {
        if let Some(handle) = &self.0 {
            handle.abort();
        }
    }
}

async fn bounded<F: Future>(future: F) -> F::Output {
    tokio::time::timeout(WAIT, future)
        .await
        .expect("readiness fixture deadline")
}

async fn drained(planner: &Planner) {
    let guard = bounded(planner.preload_lock.clone().lock_owned()).await;
    // The detached tuple may drop its mutex just before its permits. Join both
    // actual resources rather than racing a one-time available_permits read.
    let permits = bounded(
        planner
            .permits
            .clone()
            .acquire_many_owned(planner.max_concurrency),
    )
    .await
    .unwrap();
    drop(permits);
    drop(guard);
    assert_eq!(
        planner.permits.available_permits(),
        planner.max_concurrency as usize
    );
}

struct Fixture(TempDir);

impl Fixture {
    fn new() -> Self {
        Self(TempDir::new().unwrap())
    }

    fn planner(&self) -> Planner {
        Planner::new(fs::canonicalize(self.0.path()).unwrap(), 2, 8, 8192)
    }

    fn contract(&self, variant: &str) -> String {
        let contents = [
            ("tokenizer.json", "tokenizer", br#"{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"user":1,"hello":2,"world":3,"assistant":4,":":5},"unk_token":"[UNK]"}}"#.to_vec()),
            ("tokenizer_config.json", "tokenizer", br#"{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}"#.to_vec()),
            ("config.json", "config", format!(r#"{{"model_type":"fixture","variant":"{variant}"}}"#).into_bytes()),
        ];
        let artifacts: Vec<_> = contents
            .iter()
            .map(|(path, role, bytes)| PromptArtifact {
                path: (*path).into(),
                role: (*role).into(),
                size_bytes: bytes.len() as u64,
                sha256: hex::encode(Sha256::digest(bytes)),
            })
            .collect();
        let id = compute_contract_id(&artifacts, &ContractVersions::default()).unwrap();
        let directory = self.0.path().join(&id);
        fs::create_dir(&directory).unwrap();
        for (name, _, bytes) in contents {
            fs::write(directory.join(name), bytes).unwrap();
        }
        let metadata = ContractMetadata {
            schema_version: 1,
            prompt_contract_id: id.clone(),
            model_id: "fixture-model".into(),
            model_type: Some("fixture".into()),
            model_aggregate_sha256: hex::encode([0; 32]),
            artifacts,
            versions: ContractVersions::default(),
        };
        fs::write(
            directory.join(METADATA_FILE),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        id
    }

    fn request(id: &str) -> PlanRequest {
        PlanRequest {
            prompt_contract_id: id.into(),
            scope_id: "owned-readiness-fixture".into(),
            endpoint: Endpoint::ChatCompletions,
            body: json!({"model":"fixture-model","messages":[{"role":"user","content":"hello"}]}),
        }
    }
}

#[tokio::test]
async fn active_plan_finishes_before_exclusive_replacement_can_load() {
    let fixture = Fixture::new();
    let (a, c) = (
        fixture.contract("active-a"),
        fixture.contract("replacement-c"),
    );
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    let mut plan_pause = Hooks::pause_blocking(&planner.test_hooks.plan_load, &a);
    let old = planner.clone();
    let request = Fixture::request(&a);
    let plan = OwnedTask::spawn(async move { old.fixture_plan(request).await });
    plan_pause.entered().await;
    assert_eq!(planner.permits.available_permits(), 1);

    let starting = planner.test_hooks.preload_started();
    let mut loader_pause = Hooks::pause_blocking(&planner.test_hooks.preload_load, &c);
    let replacement = planner.clone();
    let selected = c.clone();
    let preload =
        OwnedTask::spawn(async move { replacement.preload_contracts(vec![selected]).await });
    bounded(starting).await.unwrap();
    assert_eq!(planner.readiness(), Readiness::Starting);
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&a))).await,
        Err(PlanError::NotReady)
    ));
    loader_pause.still_blocked().await;
    plan_pause.release();
    let (_, tokens, _, _) = plan.join().await.unwrap().unwrap();
    assert_eq!(tokens, vec![1, 5, 2, 4, 5]);
    loader_pause.entered().await;
    assert_eq!(planner.permits.available_permits(), 0);
    loader_pause.release();
    assert!(preload.join().await.unwrap().unwrap().ready);
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&a))).await,
        Err(PlanError::NotReady)
    ));
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
    drained(&planner).await;
}

#[tokio::test]
async fn early_ready_plan_rechecks_membership_after_replacement_before_loading() {
    let fixture = Fixture::new();
    let (a, c) = (fixture.contract("late-a"), fixture.contract("late-c"));
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    let mut pause = planner.test_hooks.pause_plan_permit(&a);
    let late = planner.clone();
    let request = Fixture::request(&a);
    let plan = OwnedTask::spawn(async move { late.plan(request).await });
    pause.entered().await;
    assert_eq!(planner.permits.available_permits(), 2);
    assert!(
        bounded(planner.preload_contracts(vec![c.clone()]))
            .await
            .unwrap()
            .ready
    );
    assert_eq!(
        planner.status().loaded_contracts,
        2,
        "A must still have real LRU bytes"
    );
    let before = planner.status().metrics.contract_loads;
    pause.release();
    assert!(matches!(
        plan.join().await.unwrap(),
        Err(PlanError::NotReady)
    ));
    let after = planner.status().metrics.contract_loads;
    assert_eq!(
        (before.cold, before.warm, before.waited),
        (after.cold, after.warm, after.waited)
    );
    assert_eq!(planner.test_hooks.plan_loads.load(Ordering::SeqCst), 0);
    assert_eq!(planner.permits.available_permits(), 2);
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
}

#[tokio::test]
async fn canceled_preload_waiting_for_all_permits_closes_once_and_releases_mutex() {
    let fixture = Fixture::new();
    let (a, c) = (fixture.contract("waiting-a"), fixture.contract("waiting-c"));
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    let held = bounded(planner.permits.clone().acquire_many_owned(2))
        .await
        .unwrap();
    let starting = planner.test_hooks.preload_started();
    let replacement = planner.clone();
    let selected = c.clone();
    let preload =
        OwnedTask::spawn(async move { replacement.preload_contracts(vec![selected]).await });
    bounded(starting).await.unwrap();
    assert_eq!(planner.readiness(), Readiness::Starting);
    assert!(planner.preload_lock.try_lock().is_err());
    preload.abort();
    assert!(preload.join().await.unwrap_err().is_cancelled());
    assert_eq!(planner.readiness(), Readiness::Degraded);
    assert!(planner.preload_lock.try_lock().is_ok());
    assert_eq!(planner.test_hooks.preload_loads.load(Ordering::SeqCst), 1);
    let metrics = planner.status().metrics.preloads;
    assert_eq!((metrics.runs, metrics.failed), (2, 1));
    drop(held);
    assert_eq!(planner.permits.available_permits(), 2);
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&a))).await,
        Err(PlanError::NotReady)
    ));
    assert!(
        bounded(planner.preload_contracts(vec![c.clone()]))
            .await
            .unwrap()
            .ready
    );
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
    assert_eq!(planner.status().metrics.preloads.failed, 1);
}

#[tokio::test]
async fn canceled_blocking_preload_retains_all_permits_and_mutex_until_work_ends() {
    let fixture = Fixture::new();
    let (a, b, c) = (
        fixture.contract("blocked-a"),
        fixture.contract("blocked-b"),
        fixture.contract("blocked-c"),
    );
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    let mut blocked = Hooks::pause_blocking(&planner.test_hooks.preload_load, &b);
    let replacement = planner.clone();
    let selected = b.clone();
    let preload =
        OwnedTask::spawn(async move { replacement.preload_contracts(vec![selected]).await });
    blocked.entered().await;
    assert_eq!(planner.permits.available_permits(), 0);
    preload.abort();
    assert!(preload.join().await.unwrap_err().is_cancelled());
    assert_eq!(planner.readiness(), Readiness::Degraded);
    assert_eq!(planner.permits.available_permits(), 0);
    assert!(planner.preload_lock.try_lock().is_err());
    assert!(matches!(
        bounded(planner.preload_contracts(vec![c.clone()])).await,
        Err(PreloadError::AlreadyRunning)
    ));
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&a))).await,
        Err(PlanError::NotReady)
    ));
    let metrics = planner.status().metrics.preloads;
    assert_eq!((metrics.runs, metrics.failed), (2, 1));
    blocked.release();
    drained(&planner).await;
    assert_eq!(
        planner.status().loaded_contracts,
        2,
        "detached B work must actually finish loading"
    );
    assert_eq!(
        planner.readiness(),
        Readiness::Degraded,
        "detached result published late"
    );
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&b))).await,
        Err(PlanError::NotReady)
    ));
    assert_eq!(
        planner.status().metrics.preloads.failed,
        1,
        "detached work classified failure twice"
    );
    assert!(
        bounded(planner.preload_contracts(vec![c.clone()]))
            .await
            .unwrap()
            .ready
    );
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
    assert_eq!(planner.status().metrics.preloads.failed, 1);
}

#[tokio::test]
async fn panicking_preload_worker_closes_once_and_releases_real_resources() {
    let fixture = Fixture::new();
    let (a, b, c) = (
        fixture.contract("panic-a"),
        fixture.contract("panic-b"),
        fixture.contract("panic-c"),
    );
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    *planner.test_hooks.preload_load.lock().unwrap() = Some(BlockingHook {
        id: b.clone(),
        action: BlockingAction::Panic,
    });
    assert!(matches!(
        bounded(planner.preload_contracts(vec![b])).await,
        Err(PreloadError::Worker)
    ));
    drained(&planner).await;
    assert_eq!(planner.readiness(), Readiness::Degraded);
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&a))).await,
        Err(PlanError::NotReady)
    ));
    let metrics = planner.status().metrics.preloads;
    assert_eq!((metrics.runs, metrics.failed), (2, 1));
    assert!(
        bounded(planner.preload_contracts(vec![c.clone()]))
            .await
            .unwrap()
            .ready
    );
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
    assert_eq!(planner.status().metrics.preloads.failed, 1);
}

#[path = "continuity_tests.rs"]
mod continuity;
