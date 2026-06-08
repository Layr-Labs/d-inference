package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func activeMig(batch, step int) store.ModelMigration {
	return store.ModelMigration{
		AliasID: "gemma-4-26b", FromBuild: "fp8", ToBuild: "qat",
		BatchSize: batch, MaxStepPercent: step, Status: store.MigrationActive,
	}
}

func TestAdvanceMigrationPrefetchesUnmigratedProviders(t *testing.T) {
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true, "b": true, "c": true},
		servingTo:   map[string]bool{},
		inflight:    map[string]bool{},
		healthOK:    true,
		currentTo:   0,
	}
	act := advanceMigration(activeMig(2, 25), snap)
	if len(act.prefetchTargets) != 2 {
		t.Fatalf("expected batch=2 prefetch targets, got %d", len(act.prefetchTargets))
	}
	if act.toWeight != 0 {
		t.Fatalf("no to-capacity yet → toWeight should stay 0, got %d", act.toWeight)
	}
	if act.done {
		t.Fatal("not done with zero to-providers")
	}
}

func TestAdvanceMigrationSkipsInflightAndServing(t *testing.T) {
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true, "b": true, "c": true},
		servingTo:   map[string]bool{"a": true}, // a already migrated
		inflight:    map[string]bool{"b": true}, // b downloading
		healthOK:    true,
		currentTo:   10,
	}
	act := advanceMigration(activeMig(5, 25), snap)
	// Only c is eligible (a serves to, b inflight).
	if len(act.prefetchTargets) != 1 || act.prefetchTargets[0] != "c" {
		t.Fatalf("expected only c as target, got %v", act.prefetchTargets)
	}
}

func TestAdvanceMigrationRampClampedByStep(t *testing.T) {
	// Coverage jumps to 100% but the step cap limits the ramp this tick.
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true, "b": true},
		servingTo:   map[string]bool{"a": true, "b": true},
		inflight:    map[string]bool{},
		healthOK:    true,
		currentTo:   20,
	}
	act := advanceMigration(activeMig(1, 25), snap)
	if act.toWeight != 45 { // 20 + 25 step cap
		t.Fatalf("ramp should clamp to cur+step=45, got %d", act.toWeight)
	}
	if act.fromWeight != 55 {
		t.Fatalf("fromWeight should be 100-45=55, got %d", act.fromWeight)
	}
	if act.done {
		t.Fatal("not done until toWeight reaches 100")
	}
}

func TestAdvanceMigrationCompletes(t *testing.T) {
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true, "b": true},
		servingTo:   map[string]bool{"a": true, "b": true},
		inflight:    map[string]bool{},
		healthOK:    true,
		currentTo:   90,
	}
	act := advanceMigration(activeMig(1, 25), snap)
	if act.toWeight != 100 {
		t.Fatalf("should reach 100, got %d", act.toWeight)
	}
	if !act.done {
		t.Fatal("should be done: all providers serve to and weight=100")
	}
}

func TestAdvanceMigrationHealthGateHolds(t *testing.T) {
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true, "b": true},
		servingTo:   map[string]bool{"a": true, "b": true},
		inflight:    map[string]bool{},
		healthOK:    false, // new build unhealthy
		currentTo:   30,
	}
	act := advanceMigration(activeMig(1, 25), snap)
	if act.toWeight != 30 {
		t.Fatalf("unhealthy build must freeze the weight at 30, got %d", act.toWeight)
	}
	if act.done {
		t.Fatal("must not complete while unhealthy")
	}
}

func TestAdvanceMigrationPausedHolds(t *testing.T) {
	m := activeMig(1, 25)
	m.Status = store.MigrationPaused
	snap := migrationSnapshot{
		servingFrom: map[string]bool{"a": true},
		servingTo:   map[string]bool{},
		inflight:    map[string]bool{},
		healthOK:    true,
		currentTo:   40,
	}
	act := advanceMigration(m, snap)
	if len(act.prefetchTargets) != 0 {
		t.Fatalf("paused migration must not prefetch, got %v", act.prefetchTargets)
	}
	if act.toWeight != 40 {
		t.Fatalf("paused migration holds weight at 40, got %d", act.toWeight)
	}
}

// Full lifecycle simulation: cur weight follows coverage as providers migrate,
// driven only by advanceMigration (no timers/registry).
func TestAdvanceMigrationLifecycleConverges(t *testing.T) {
	m := activeMig(1, 25)
	from := map[string]bool{"a": true, "b": true, "c": true, "d": true}
	to := map[string]bool{}
	cur := 0
	// Each "round" one more provider finishes prefetch and re-advertises `to`.
	order := []string{"a", "b", "c", "d"}
	migrated := 0
	for tick := 0; tick < 50; tick++ {
		snap := migrationSnapshot{servingFrom: from, servingTo: to, inflight: map[string]bool{}, healthOK: true, currentTo: cur}
		act := advanceMigration(m, snap)
		cur = act.toWeight
		if act.done {
			break
		}
		// Simulate a target finishing its download before the next tick.
		if migrated < len(order) {
			to[order[migrated]] = true
			migrated++
		}
	}
	if cur != 100 {
		t.Fatalf("migration did not converge to 100%%, ended at %d", cur)
	}
}

// Admin can start a migration; it persists and ensures the alias holds both
// builds (to drained at 0).
func TestMigrationStartEndpoint(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{{BuildID: fp8, Weight: 100, Active: true}},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	body, _ := json.Marshal(map[string]any{
		"alias_id": "gemma-4-26b", "from_build": fp8, "to_build": qat,
		"batch_size": 2, "max_step_percent": 20,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/migrations", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("start migration status = %d body = %s", rec.Code, rec.Body.String())
	}

	m, ok, err := st.GetModelMigration("gemma-4-26b")
	if err != nil || !ok {
		t.Fatalf("migration not persisted: ok=%v err=%v", ok, err)
	}
	if m.Status != store.MigrationActive || m.ToBuild != qat || m.BatchSize != 2 {
		t.Fatalf("migration fields wrong: %+v", m)
	}
	// Alias now carries both builds, to drained at 0.
	alias, _, _ := st.GetModelAlias("gemma-4-26b")
	if buildWeight(alias, qat) != 0 || buildWeight(alias, fp8) != 100 {
		t.Fatalf("alias build weights wrong: %+v", alias.Builds)
	}

	// Rollback reverts cleanly.
	rb := httptest.NewRequest(http.MethodPost, "/v1/admin/migrations/gemma-4-26b/rollback", nil)
	rb.Header.Set("Authorization", "Bearer publish-secret")
	rbRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rbRec, rb)
	if rbRec.Code != http.StatusOK {
		t.Fatalf("rollback status = %d body=%s", rbRec.Code, rbRec.Body.String())
	}
	m2, _, _ := st.GetModelMigration("gemma-4-26b")
	if m2.Status != store.MigrationRolledBack {
		t.Fatalf("rollback status = %q", m2.Status)
	}
}

// Starting a second migration for an alias while one is already active is
// rejected (409). Overlapping migrations would strand the prior split's builds
// at nonzero weight, so the operator must pause/rollback the active one first.
func TestMigrationStartRejectsActiveMigration(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	const qat2 = "mlx-community/gemma-4-26B-A4B-it-qat-5bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")
	seedActiveModel(t, st, qat2, "qat2")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{{BuildID: fp8, Weight: 100, Active: true}},
	}); err != nil {
		t.Fatal(err)
	}

	start := func(from, to string) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]any{
			"alias_id": "gemma-4-26b", "from_build": from, "to_build": to,
			"batch_size": 2, "max_step_percent": 20,
		})
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/migrations", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	if rec := start(fp8, qat); rec.Code != http.StatusOK {
		t.Fatalf("first start = %d body=%s", rec.Code, rec.Body.String())
	}
	// Second start while the first is active must be rejected with 409.
	if rec := start(fp8, qat2); rec.Code != http.StatusConflict {
		t.Fatalf("second start status = %d (want 409); body=%s", rec.Code, rec.Body.String())
	}
	// The active migration must be unchanged by the rejected start (still →qat).
	if m, ok, _ := st.GetModelMigration("gemma-4-26b"); !ok || m.ToBuild != qat {
		t.Fatalf("active migration was mutated by the rejected start: %+v", m)
	}

	// Pausing does NOT make a restart safe (the paused split's `to` build stays at
	// nonzero weight), so a paused migration also blocks a new start.
	pause := httptest.NewRequest(http.MethodPost, "/v1/admin/migrations/gemma-4-26b/pause", nil)
	pause.Header.Set("Authorization", "Bearer publish-secret")
	pauseRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(pauseRec, pause)
	if pauseRec.Code != http.StatusOK {
		t.Fatalf("pause = %d body=%s", pauseRec.Code, pauseRec.Body.String())
	}
	if rec := start(fp8, qat2); rec.Code != http.StatusConflict {
		t.Fatalf("start while paused = %d (want 409); body=%s", rec.Code, rec.Body.String())
	}

	// After rollback, a new migration is allowed again (the guard only blocks
	// while a migration is ACTIVE or PAUSED, not after it is rolled back).
	rb := httptest.NewRequest(http.MethodPost, "/v1/admin/migrations/gemma-4-26b/rollback", nil)
	rb.Header.Set("Authorization", "Bearer publish-secret")
	rbRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rbRec, rb)
	if rbRec.Code != http.StatusOK {
		t.Fatalf("rollback = %d body=%s", rbRec.Code, rbRec.Body.String())
	}
	if rec := start(fp8, qat2); rec.Code != http.StatusOK {
		t.Fatalf("start after rollback = %d body=%s", rec.Code, rec.Body.String())
	}
}

// Deleting an alias must also remove its migration — otherwise the controller
// would keep ramping and applyWeights would recreate the deleted alias.
func TestDeletingAliasStopsMigration(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", Active: true,
		Builds: []store.ModelAliasBuild{{BuildID: fp8, Weight: 100, Active: true}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertModelMigration(&store.ModelMigration{
		AliasID: "gemma-4-26b", FromBuild: fp8, ToBuild: qat, Status: store.MigrationActive,
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/v1/admin/models/aliases/gemma-4-26b", nil)
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("delete alias status = %d body=%s", rec.Code, rec.Body.String())
	}
	if _, ok, _ := st.GetModelMigration("gemma-4-26b"); ok {
		t.Fatal("migration should be removed when its alias is deleted")
	}
	if _, ok, _ := st.GetModelAlias("gemma-4-26b"); ok {
		t.Fatal("alias should be deleted")
	}
}
