use super::*;

#[tokio::test]
async fn incremental_retry_keeps_healthy_plan_runnable_and_cancellation_owned() {
    let fixture = Fixture::new();
    let a = fixture.contract("continuity-a");
    let b = fixture.contract("continuity-b");
    let planner = fixture.planner();
    assert!(
        bounded(planner.preload_incremental_contracts(vec![a.clone()]))
            .await
            .unwrap()
            .ready
    );
    let mut pause = Hooks::pause_blocking(&planner.test_hooks.preload_load, &b);
    let worker = planner.clone();
    let ids = vec![a.clone(), b.clone()];
    let preload = OwnedTask::spawn(async move { worker.preload_incremental_contracts(ids).await });
    pause.entered().await;
    assert_eq!(planner.readiness(), Readiness::Ready);
    assert_eq!(planner.permits.available_permits(), 1);
    let (_, tokens, _, _) = bounded(planner.fixture_plan(Fixture::request(&a)))
        .await
        .unwrap();
    assert_eq!(tokens, vec![1, 5, 2, 4, 5]);
    assert!(matches!(
        bounded(planner.plan(Fixture::request(&b))).await,
        Err(PlanError::NotReady)
    ));
    preload.abort();
    assert!(preload.join().await.unwrap_err().is_cancelled());
    assert!(planner.readiness.allows(&a));
    assert!(!planner.readiness.allows(&b));
    assert_eq!(planner.permits.available_permits(), 1);
    assert!(matches!(
        planner.preload_incremental_contracts(vec![a.clone()]).await,
        Err(PreloadError::AlreadyRunning)
    ));
    bounded(planner.plan(Fixture::request(&a))).await.unwrap();
    pause.release();
    drained(&planner).await;
    assert!(
        !planner.readiness.allows(&b),
        "detached load cannot publish an unacknowledged addition"
    );
    assert!(
        planner
            .preload_incremental_contracts(vec![a.clone(), b.clone()])
            .await
            .unwrap()
            .ready
    );
    assert!(matches!(
        planner.preload_contracts(vec![a.clone()]).await,
        Err(PreloadError::LegacyDisabled)
    ));
    bounded(planner.plan(Fixture::request(&a))).await.unwrap();
}

#[tokio::test]
async fn incremental_swap_defers_capacity_until_removed_active_plan_retires() {
    let fixture = Fixture::new();
    let (a, b, c) = (
        fixture.contract("swap-a"),
        fixture.contract("swap-b"),
        fixture.contract("swap-c"),
    );
    let planner = Planner::new(fs::canonicalize(fixture.0.path()).unwrap(), 3, 2, 8192);
    assert!(
        planner
            .preload_incremental_contracts(vec![a.clone(), b.clone()])
            .await
            .unwrap()
            .ready
    );
    let mut pause = Hooks::pause_blocking(&planner.test_hooks.plan_load, &a);
    let worker = planner.clone();
    let request = Fixture::request(&a);
    let plan = OwnedTask::spawn(async move { worker.plan(request).await });
    pause.entered().await;
    let report = planner
        .preload_incremental_contracts(vec![b.clone(), c.clone()])
        .await
        .unwrap();
    assert!(!report.ready);
    assert!(planner.readiness.allows(&b));
    assert!(!planner.readiness.allows(&a));
    assert!(!planner.readiness.allows(&c));
    assert_eq!(planner.status().loaded_contracts, 2);
    assert_eq!(planner.status().loading_contracts, 0);
    bounded(planner.plan(Fixture::request(&b))).await.unwrap();
    pause.release();
    plan.join().await.unwrap().unwrap();
    drained(&planner).await;
    assert!(
        planner
            .preload_incremental_contracts(vec![b.clone(), c.clone()])
            .await
            .unwrap()
            .ready
    );
    assert_eq!(planner.status().loaded_contracts, 2);
    assert!(planner.cache.resident(&a).is_none());
    bounded(planner.plan(Fixture::request(&c))).await.unwrap();
}

#[tokio::test]
async fn incremental_initial_transition_cancellation_preserves_prior_worker_ownership() {
    let fixture = Fixture::new();
    let a = fixture.contract("transition-a");
    let b = fixture.contract("transition-b");
    let planner = fixture.planner();
    assert!(
        planner
            .preload_contracts(vec![a.clone()])
            .await
            .unwrap()
            .ready
    );
    let mut pause = Hooks::pause_blocking(&planner.test_hooks.plan_load, &a);
    let worker = planner.clone();
    let request = Fixture::request(&a);
    let plan = OwnedTask::spawn(async move { worker.plan(request).await });
    pause.entered().await;
    let waiting = planner.test_hooks.preload_started();
    let worker = planner.clone();
    let ids = vec![a.clone(), b.clone()];
    let preload = OwnedTask::spawn(async move { worker.preload_incremental_contracts(ids).await });
    bounded(waiting).await.unwrap();
    assert!(!planner.continuity.load(Ordering::Acquire));
    preload.abort();
    assert!(preload.join().await.unwrap_err().is_cancelled());
    assert!(planner.readiness.allows(&a));
    assert!(!planner.readiness.allows(&b));
    assert!(!planner.continuity.load(Ordering::Acquire));
    assert_eq!(planner.permits.available_permits(), 1);
    pause.release();
    plan.join().await.unwrap().unwrap();
    drained(&planner).await;
    assert!(
        planner
            .preload_incremental_contracts(vec![a, b])
            .await
            .unwrap()
            .ready
    );
    assert!(planner.continuity.load(Ordering::Acquire));
}
#[tokio::test]
async fn incremental_concurrency_one_preserves_membership_but_reports_worker_capacity() {
    let fixture = Fixture::new();
    let a = fixture.contract("single-a");
    let b = fixture.contract("single-b");
    let planner = Planner::new(fs::canonicalize(fixture.0.path()).unwrap(), 1, 2, 8192);
    planner
        .preload_incremental_contracts(vec![a.clone()])
        .await
        .unwrap();
    let mut pause = Hooks::pause_blocking(&planner.test_hooks.preload_load, &b);
    let worker = planner.clone();
    let ids = vec![a.clone(), b.clone()];
    let preload = OwnedTask::spawn(async move { worker.preload_incremental_contracts(ids).await });
    pause.entered().await;
    assert!(planner.readiness.allows(&a));
    assert!(matches!(
        planner.plan(Fixture::request(&a)).await,
        Err(PlanError::AtCapacity)
    ));
    pause.release();
    assert!(preload.join().await.unwrap().unwrap().ready);
    drained(&planner).await;
    planner.plan(Fixture::request(&a)).await.unwrap();
}
