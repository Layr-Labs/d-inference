package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestLegacyCacheAffinityScrubMigration(t *testing.T) {
	for _, required := range []string{
		"scrub_inference_route_cache_affinity_v1",
		"UPDATE inference_routes SET cache_affinity_key = ''",
		"INSERT INTO schema_migrations",
	} {
		if !strings.Contains(legacyCacheAffinityScrubMigration, required) {
			t.Fatalf("legacy cache-affinity scrub migration missing %q", required)
		}
	}
	if !strings.Contains(legacyCacheAffinityGuardFunction, "NEW.cache_affinity_key := ''") ||
		!strings.Contains(legacyCacheAffinityGuardTrigger, "BEFORE INSERT OR UPDATE OF cache_affinity_key") {
		t.Fatal("legacy cache-affinity write guard is incomplete")
	}
	for _, required := range []string{
		"tg.tgrelid",
		"target.relname = 'inference_routes'",
		"ns.nspname = current_schema()",
	} {
		if !strings.Contains(legacyCacheAffinityGuardTrigger, required) {
			t.Fatalf("legacy cache-affinity trigger existence check missing %q", required)
		}
	}
}

func TestLegacyCacheAffinityMigrationScrubsAndInstallsScopedTrigger(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	schema := fmt.Sprintf("cache_affinity_migration_%d", time.Now().UnixNano())
	if _, err := s.pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatalf("create isolated schema: %v", err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
	})

	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire isolated migration connection: %v", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SET search_path TO "+schema); err != nil {
		t.Fatalf("set isolated search_path: %v", err)
	}
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE inference_routes (
			id BIGSERIAL PRIMARY KEY,
			cache_affinity_key TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE trigger_name_conflict (
			id BIGSERIAL PRIMARY KEY,
			cache_affinity_key TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE FUNCTION clear_legacy_cache_affinity_key()
			RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$`,
		`CREATE TRIGGER clear_legacy_cache_affinity_key
			BEFORE INSERT OR UPDATE OF cache_affinity_key ON trigger_name_conflict
			FOR EACH ROW EXECUTE FUNCTION clear_legacy_cache_affinity_key()`,
		`INSERT INTO inference_routes (cache_affinity_key) VALUES ('legacy-secret')`,
	} {
		if _, err := conn.Exec(ctx, statement); err != nil {
			t.Fatalf("prepare legacy schema: %v\n%s", err, statement)
		}
	}

	for _, migration := range []string{
		legacyCacheAffinityGuardFunction,
		legacyCacheAffinityGuardTrigger,
		legacyCacheAffinityScrubMigration,
	} {
		if _, err := conn.Exec(ctx, migration); err != nil {
			t.Fatalf("run cache-affinity migration: %v\n%s", err, migration)
		}
	}

	var scrubbed string
	if err := conn.QueryRow(ctx,
		"SELECT cache_affinity_key FROM inference_routes").Scan(&scrubbed); err != nil {
		t.Fatalf("read scrubbed route: %v", err)
	}
	if scrubbed != "" {
		t.Fatalf("legacy cache affinity survived migration: %q", scrubbed)
	}
	var marked bool
	if err := conn.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM schema_migrations
			WHERE id = 'scrub_inference_route_cache_affinity_v1'
		)`).Scan(&marked); err != nil {
		t.Fatalf("read scrub marker: %v", err)
	}
	if !marked {
		t.Fatal("legacy cache-affinity scrub marker was not recorded")
	}
	var triggerCount int
	if err := conn.QueryRow(ctx, `
		SELECT count(*)
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_legacy_cache_affinity_key'
		  AND NOT tg.tgisinternal
		  AND ns.nspname = current_schema()
		`).Scan(&triggerCount); err != nil {
		t.Fatalf("count scoped triggers: %v", err)
	}
	if triggerCount != 2 {
		t.Fatalf("scoped trigger count = %d, want conflict table + inference_routes", triggerCount)
	}

	var inserted, updated string
	if err := conn.QueryRow(ctx, `
		INSERT INTO inference_routes (cache_affinity_key)
		VALUES ('new-secret')
		RETURNING cache_affinity_key`).Scan(&inserted); err != nil {
		t.Fatalf("insert guarded route: %v", err)
	}
	if err := conn.QueryRow(ctx, `
		UPDATE inference_routes
		SET cache_affinity_key = 'replacement-secret'
		RETURNING cache_affinity_key`).Scan(&updated); err != nil {
		t.Fatalf("update guarded route: %v", err)
	}
	if inserted != "" || updated != "" {
		t.Fatalf("trigger did not scrub future writes: insert=%q update=%q", inserted, updated)
	}

	// A restart must remain idempotent with both same-named triggers present.
	for _, migration := range []string{
		legacyCacheAffinityGuardFunction,
		legacyCacheAffinityGuardTrigger,
		legacyCacheAffinityScrubMigration,
	} {
		if _, err := conn.Exec(ctx, migration); err != nil {
			t.Fatalf("re-run cache-affinity migration: %v", err)
		}
	}
}

func TestInferenceRoute_Memory(t *testing.T) {
	s := NewMemory(Config{})
	testInferenceRouteStore(t, s)
}

func TestInferenceRoute_Postgres(t *testing.T) {
	s := testPostgresStore(t)
	testInferenceRouteStore(t, s)
}

func testInferenceRouteStore(t *testing.T, s Store) {
	t.Helper()

	beforeRecord := time.Now().Add(-time.Minute)

	rec := &InferenceRouteRecord{
		RequestID:               "req-1",
		Attempt:                 1,
		ProviderID:              "prov-1",
		Model:                   "mlx-community/Qwen3.5-9B-MLX-4bit",
		PublicModel:             "qwen3.5-9b",
		ConsumerKeyHash:         "abc123hash",
		KeyID:                   "key_123",
		Outcome:                 "routed",
		CostMs:                  12.5,
		StateMs:                 3.0,
		QueueMs:                 1.5,
		PendingMs:               0.5,
		BacklogMs:               0.25,
		ThisReqMs:               2.0,
		HealthMs:                1.0,
		TTFTMs:                  50.0,
		BestTTFTMs:              40.0,
		EffectiveQueue:          2,
		CandidateCount:          4,
		CapacityRejections:      1,
		ModelTooLargeRejections: 0,
		VisionRejections:        0,
		TTFTRejections:          0,
		EffectiveTPS:            45.2,
		StaticTPS:               38.0,
		ProviderStatus:          "idle",
		ProviderTrustLevel:      "attested",
		ProviderVersion:         "0.5.0",
		HardwareChip:            "Apple M3 Max",
		HardwareChipFamily:      "M3",
		HardwareTier:            "high",
		MemoryGB:                128,
		GPUCores:                40,
		CPUCores:                16,
		SystemMemoryPressure:    0.2,
		SystemCPUUsage:          0.15,
		SystemThermalState:      "Nominal",
		GPUMemoryActiveGB:       8.5,
		GPUMemoryPeakGB:         12.0,
		GPUMemoryCacheGB:        2.0,
		SlotState:               "idle",
		BackendRunning:          1,
		BackendWaiting:          0,
		ActiveTokenBudgetUsed:   1000,
		ActiveTokenBudgetMax:    4096,
		QueuedTokenBudget:       0,
		EstimatedPromptTokens:   500,
		RequestedMaxTokens:      1024,
		RequiresVision:          true,
		HasTools:                false,
		SelfRouteOnly:           false,
		PreferOwner:             true,
	}

	if err := s.RecordInferenceRoute(rec); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}

	// Lookup by request_id via zero-time since returns all records.
	all := s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("InferenceRouteRecordsSince(zero) = %d records, want 1", len(all))
	}
	encoded, err := json.Marshal(all[0])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "cache_affinity_key") {
		t.Fatalf("route telemetry serialized legacy cache key material: %s", encoded)
	}
	got := all[0]
	if got.RequestID != "req-1" || got.Attempt != 1 || got.ProviderID != "prov-1" {
		t.Errorf("record mismatch: got request_id=%q attempt=%d provider_id=%q", got.RequestID, got.Attempt, got.ProviderID)
	}
	if got.Model != rec.Model || got.PublicModel != rec.PublicModel {
		t.Errorf("model/public_model mismatch: got %q/%q want %q/%q", got.Model, got.PublicModel, rec.Model, rec.PublicModel)
	}
	if got.Outcome != "routed" {
		t.Errorf("outcome = %q, want routed", got.Outcome)
	}
	if got.CostMs != 12.5 {
		t.Errorf("cost_ms = %f, want 12.5", got.CostMs)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Error("created_at and updated_at should be set")
	}
	if !got.CreatedAt.After(beforeRecord) {
		t.Error("created_at should be after beforeRecord")
	}

	// RecordsSince filters out older records.
	old := s.InferenceRouteRecordsSince(time.Now().Add(time.Hour))
	if len(old) != 0 {
		t.Fatalf("InferenceRouteRecordsSince(future) = %d records, want 0", len(old))
	}

	// Update outcome.
	beforeUpdate := time.Now()
	outcome := &InferenceRouteOutcome{
		FinalStatus:            "success",
		ErrorCode:              0,
		ErrorClass:             "",
		ErrorReason:            "",
		PromptTokens:           50,
		CompletionTokens:       100,
		ReasoningTokens:        10,
		CostMicroUSD:           2500,
		ActualTTFTMs:           150.0,
		DispatchToFirstChunkMs: 180.0,
		TotalDurationMs:        1200.0,
		ParseMs:                1,
		ReserveMs:              2,
		RouteMs:                3,
		EncryptMs:              4,
		QueueWaitMs:            5,
		DispatchMs:             6,
		ActualDecodeTPS:        42,
		AdmittedButFailed:      true,
		UsedBackup:             true,
		BackupWon:              true,
	}
	if err := s.UpdateInferenceRouteOutcome("req-1", 1, outcome); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}

	all = s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("after update: expected 1 record, got %d", len(all))
	}
	if all[0].UpdatedAt.IsZero() {
		t.Error("updated_at should not be zero after update")
	}
	if !all[0].UpdatedAt.After(beforeUpdate) {
		// Allow a small amount of clock skew between process and DB for Postgres.
		if all[0].UpdatedAt.Sub(beforeUpdate) < -time.Second {
			t.Errorf("updated_at should be after beforeUpdate, got %v (beforeUpdate %v)", all[0].UpdatedAt, beforeUpdate)
		}
	}
	if all[0].FinalStatus != "success" || all[0].PromptTokens != 50 || all[0].CompletionTokens != 100 || all[0].ReasoningTokens != 10 {
		t.Errorf("outcome tokens/status not exposed on route record: %+v", all[0])
	}
	if all[0].CostMicroUSD != 2500 || all[0].ActualTTFTMs != 150 || all[0].DispatchToFirstChunkMs != 180 || all[0].TotalDurationMs != 1200 {
		t.Errorf("outcome cost/timing not exposed on route record: %+v", all[0])
	}
	if all[0].ParseMs != 1 || all[0].ReserveMs != 2 || all[0].RouteMs != 3 || all[0].EncryptMs != 4 || all[0].QueueWaitMs != 5 || all[0].DispatchMs != 6 {
		t.Errorf("latency decomposition not exposed on route record: %+v", all[0])
	}
	if all[0].ActualDecodeTPS != 42 || !all[0].AdmittedButFailed || !all[0].UsedBackup || !all[0].BackupWon {
		t.Errorf("decode/backup flags not exposed on route record: %+v", all[0])
	}

	if err := s.UpdateInferenceRouteOutcome("req-1", 1, &InferenceRouteOutcome{FinalStatus: "error", ErrorClass: "provider_error", ErrorCode: 500, ErrorReason: "jinja_template"}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome error reason: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	if all[0].ErrorReason != "jinja_template" {
		t.Errorf("error_reason not exposed on route record: %+v", all[0])
	}

	// A later latency-only committed update must not erase the terminal status or
	// token/cost fields.
	if err := s.UpdateInferenceRouteOutcome("req-1", 1, &InferenceRouteOutcome{ActualTTFTMs: 175}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome latency-only: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	if all[0].FinalStatus != "error" || all[0].PromptTokens != 50 || all[0].CostMicroUSD != 2500 || all[0].ActualTTFTMs != 175 || all[0].ErrorReason != "jinja_template" {
		t.Errorf("latency-only outcome update should merge, got %+v", all[0])
	}

	// Record a second attempt for the same request and verify lookup by request_id.
	rec2 := &InferenceRouteRecord{
		RequestID:  "req-1",
		Attempt:    2,
		ProviderID: "prov-2",
		Model:      rec.Model,
		Outcome:    "fallback",
	}
	if err := s.RecordInferenceRoute(rec2); err != nil {
		t.Fatalf("RecordInferenceRoute attempt 2: %v", err)
	}

	all = s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 2 {
		t.Fatalf("expected 2 records, got %d", len(all))
	}

	// Records should be newest-first (by created_at).
	if all[0].Attempt != 2 {
		t.Errorf("first record attempt = %d, want 2", all[0].Attempt)
	}
	if all[1].Attempt != 1 {
		t.Errorf("second record attempt = %d, want 1", all[1].Attempt)
	}

	queued := &InferenceRouteRecord{
		RequestID: "req-queued",
		Attempt:   0,
		Model:     rec.Model,
		Outcome:   "queued",
	}
	if err := s.RecordInferenceRoute(queued); err != nil {
		t.Fatalf("RecordInferenceRoute queued: %v", err)
	}
	queuedSelected := *queued
	queuedSelected.ProviderID = "prov-queued"
	queuedSelected.Outcome = "selected"
	queuedSelected.ProviderStatus = "serving"
	queuedSelected.HardwareChip = "Apple M4 Max"
	if err := s.RecordInferenceRoute(&queuedSelected); err != nil {
		t.Fatalf("RecordInferenceRoute queued selected refresh: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	var queuedGot *InferenceRouteRecord
	queuedCount := 0
	for i := range all {
		if all[i].RequestID == "req-queued" {
			queuedCount++
			queuedGot = &all[i]
		}
	}
	if queuedCount != 1 || queuedGot == nil {
		t.Fatalf("queued route rows = %d, want 1", queuedCount)
	}
	if queuedGot.ProviderID != "prov-queued" || queuedGot.Outcome != "selected" || queuedGot.HardwareChip != "Apple M4 Max" {
		t.Fatalf("queued route snapshot was not refreshed with serving provider: %+v", queuedGot)
	}

	// Updating a non-existent attempt is best-effort and returns no error.
	if err := s.UpdateInferenceRouteOutcome("req-missing", 99, outcome); err != nil {
		t.Errorf("UpdateInferenceRouteOutcome missing record: %v", err)
	}
}

func TestRejection_Memory(t *testing.T) {
	s := NewMemory(Config{})
	testRejectionStore(t, s)
}

func TestRejection_Postgres(t *testing.T) {
	s := testPostgresStore(t)
	testRejectionStore(t, s)
}

func testRejectionStore(t *testing.T, s Store) {
	t.Helper()

	beforeRecord := time.Now().Add(-time.Minute)

	rec := &RejectionRecord{
		RequestID:               "req-rej-1",
		Endpoint:                "/v1/chat/completions",
		Stage:                   "preflight_capacity",
		ReasonCode:              "machine_busy",
		HTTPStatus:              429,
		ConsumerKeyHash:         "abc123hash",
		KeyID:                   "key_123",
		ClientClass:             "openrouter",
		RequestedModel:          "mlx-community/Qwen3.5-9B-MLX-4bit",
		ResolvedModel:           "qwen3.5-9b",
		Stream:                  true,
		N:                       1,
		EstimatedPromptTokens:   500,
		RequestedMaxTokens:      1024,
		RequiresVision:          true,
		HasImage:                true,
		HasAudio:                false,
		HasTools:                false,
		ToolCount:               0,
		ResponseFormat:          "json_object",
		SelfRouteOnly:           false,
		PreferOwner:             true,
		Params:                  json.RawMessage(`{"temperature":0.7}`),
		RequestBodyBytes:        2048,
		RetryAfterMs:            1500,
		CouldHaveServed:         true,
		CandidateCount:          4,
		CapacityRejections:      3,
		ModelTooLargeRejections: 1,
		VisionRejections:        0,
		WarmProviderExisted:     true,
		BestTTFTMs:              42.5,
		ShortfallMicroUSD:       0,
		LimitKind:               "itpm",
		OverBy:                  120,
	}

	if err := s.RecordRejection(rec); err != nil {
		t.Fatalf("RecordRejection: %v", err)
	}

	// Zero-time since returns all records.
	all := s.RejectionRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("RejectionRecordsSince(zero) = %d records, want 1", len(all))
	}
	got := all[0]
	if got.Stage != "preflight_capacity" {
		t.Errorf("stage = %q, want preflight_capacity", got.Stage)
	}
	if got.ReasonCode != "machine_busy" {
		t.Errorf("reason_code = %q, want machine_busy", got.ReasonCode)
	}
	if got.HTTPStatus != 429 {
		t.Errorf("http_status = %d, want 429", got.HTTPStatus)
	}
	if got.RequestedModel != rec.RequestedModel {
		t.Errorf("requested_model = %q, want %q", got.RequestedModel, rec.RequestedModel)
	}
	if !got.CouldHaveServed {
		t.Error("could_have_served = false, want true")
	}
	if got.CandidateCount != 4 {
		t.Errorf("candidate_count = %d, want 4", got.CandidateCount)
	}
	if got.CreatedAt.IsZero() {
		t.Error("created_at should be set")
	}
	if !got.CreatedAt.After(beforeRecord) {
		t.Error("created_at should be after beforeRecord")
	}

	// RecordsSince filters out older records.
	old := s.RejectionRecordsSince(time.Now().Add(time.Hour))
	if len(old) != 0 {
		t.Fatalf("RejectionRecordsSince(future) = %d records, want 0", len(old))
	}

	// A second rejection at a different stage; records are newest-first.
	rec2 := &RejectionRecord{
		RequestID:      "req-rej-2",
		Endpoint:       "/v1/chat/completions",
		Stage:          "model_resolution",
		ReasonCode:     "model_not_found",
		HTTPStatus:     404,
		RequestedModel: "no-such-model",
	}
	if err := s.RecordRejection(rec2); err != nil {
		t.Fatalf("RecordRejection attempt 2: %v", err)
	}

	all = s.RejectionRecordsSince(time.Time{})
	if len(all) != 2 {
		t.Fatalf("expected 2 records, got %d", len(all))
	}
	if all[0].RequestID != "req-rej-2" {
		t.Errorf("first record request_id = %q, want req-rej-2 (newest-first)", all[0].RequestID)
	}
	if all[1].RequestID != "req-rej-1" {
		t.Errorf("second record request_id = %q, want req-rej-1", all[1].RequestID)
	}
}
