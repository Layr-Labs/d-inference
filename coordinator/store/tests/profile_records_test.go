package store_test

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func i64p(v int64) *int64 { return &v }

func intp(v int) *int { return &v }

func boolp(v bool) *bool { return &v }

// canonicalJSON re-encodes raw with sorted keys and no whitespace so a JSONB
// round trip (which normalises both) compares equal. Empty stays nil.
func canonicalJSON(t *testing.T, raw json.RawMessage) json.RawMessage {
	t.Helper()
	if len(raw) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("invalid JSON %q: %v", raw, err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	return b
}

func normalizeProfile(t *testing.T, r store.RequestProfileRecord) store.RequestProfileRecord {
	t.Helper()
	r.ReceivedAt = r.ReceivedAt.UTC().Truncate(time.Microsecond)
	r.CreatedAt = r.CreatedAt.UTC().Truncate(time.Microsecond)
	r.GateRejections = canonicalJSON(t, r.GateRejections)
	r.Candidates = canonicalJSON(t, r.Candidates)
	r.ProviderProfile = canonicalJSON(t, r.ProviderProfile)
	return r
}

func normalizeSnapshot(t *testing.T, f store.FleetSnapshotRow) store.FleetSnapshotRow {
	t.Helper()
	f.SampledAt = f.SampledAt.UTC().Truncate(time.Microsecond)
	f.QueueDepthByModel = canonicalJSON(t, f.QueueDepthByModel)
	return f
}

// fullProfile fills every field with a distinctive value so a round trip
// exercises every column. Pointer fields mix nil, pointer-to-zero and
// pointer-to-value; non-pointer zero values are left at zero deliberately.
func fullProfile(requestID string, attempt int, at time.Time) *store.RequestProfileRecord {
	return &store.RequestProfileRecord{
		CoordRequestID: "coord-" + requestID, RequestID: requestID, Attempt: attempt,
		BackupOf: "", Winning: true, Endpoint: "POST /v1/chat/completions", Stream: true,
		Model: "qwen3-30b", PublicModel: "qwen", ProviderID: "prov-a", ProviderVersion: "0.8.13",
		ChipFamily: "m3", KVBackend: "paged", FinalStatus: "ok", ErrorReason: "", TerminalCause: "complete",
		ClientOutcome: "done", ProviderOutcome: "complete", ClientGonePhase: "", FirstContentBudgetMs: 4000,
		AdmissionMode: "hard", PredictiveBypass: "none", ReservationTTFTCeilingMs: ptrF64(3500.5), DispatchBudgetMs: i64p(3401), EstimatedPromptTokens: 1500, RequestedMaxTokens: 512, RequiresVision: true, HasTools: true,
		ReceivedAt: at.Add(-time.Second),

		AuthDoneUS: i64p(10), RatelimitDoneUS: i64p(20), SealedOpenUS: nil, HandlerEntryUS: i64p(0),
		ParsedUS: i64p(40), ReservedUS: i64p(50), MediaFetchedUS: nil, PreflightDoneUS: i64p(70),
		PlanDoneUS: i64p(80), AttemptStartUS: i64p(90), ReserveLockAcquiredUS: i64p(91), ReserveDoneUS: i64p(92),
		QueuedUS: nil, DequeuedUS: nil, TopupDoneUS: i64p(100), EncryptedUS: i64p(110),
		WriteSubmittedUS: i64p(120), WriteDequeuedUS: i64p(121), WriteDoneUS: i64p(122), AcceptedUS: i64p(130),
		FirstChunkIngressUS: i64p(200), FirstChunkDequeuedUS: i64p(201), FirstContentIngressUS: i64p(210),
		FirstContentUS: i64p(211), HeadersWrittenUS: i64p(212), FirstFlushUS: i64p(213), LastFlushUS: i64p(900),
		ClientGoneUS: nil, CancelSentUS: nil, CompleteIngressUS: i64p(950), DoneFlushedUS: i64p(960),
		FinalizedUS: i64p(970), SettleDBUS: i64p(5), DBUS: i64p(0), DBCalls: 3,

		BodyBytes: 1234, SealedBodyBytes: 1300, AuthKind: "api_key", AuthDBRead: true, ReserveMode: "ttft",
		MediaItems: 0, MediaBytes: 0, PreflightOutcome: "pass", PlanOutcome: "single", ChunksIn: 40, ChunksOut: 39,
		BytesOut: 8192, DecryptUSTotal: 300, MaxChunkGapUS: 45000, HeldPreambleChunks: 1, ClientWriteErr: false,
		AttemptsTotal: 1, FailedAttempts: 0, FailedAttemptsUS: 0, BackupLaunched: false, BackupWon: false,
		TransportEstUS: i64p(15000), SleptUS: nil, TimingAnomaly: false,

		CandidateSetSize: 12, Scanned: 12, GateRejections: json.RawMessage(`{"offline": 2, "breaker": 1}`),
		RunnerUpProviderID: "prov-b", RunnerUpCostMs: 812.5, NearTiePoolSize: 2, SelectionPath: "unique_min",
		BestIdleProviderID: "prov-c", BestIdleTTFTMs: 400.25, PredictedTTFTMs: 350.5, RawTTFTMs: 300.75,
		PredictedDecodeTPS: 55.5, SnapshotAgeMs: 900, PendingForModel: 2, TotalPending: 7,
		CapacityRateMs: 12.5, CacheDiscountMs: 0, ShadowWouldShed: boolp(false), ShadowIdleAlternative: nil,
		LockWaitUS: 12, ScanUS: 34, AdmitUS: 56, PreflightUS: 78, TTFTCalibrationRatio: 1.1, PrefillDecodeRatio: 0.4,
		QueuePositionAtEnqueue: 0, QueueDepthAtEnqueue: 0, DrainTrigger: "",
		Candidates: json.RawMessage(`[{"provider_id":"prov-a","cost_ms":800.5},{"provider_id":"prov-b","cost_ms":812.5}]`),

		ProvTotalUS: i64p(700000), ProvFirstDeltaUS: i64p(150000), ProvEngineSubmitUS: i64p(100), ProvEngineAdmittedUS: i64p(200),
		ProvPromptPrepUS: i64p(3000), ProvLoadWaitUS: nil, ProvLoadCold: boolp(false), ProvRunningAtAdmit: intp(0),
		ProvWaitingAtAdmit: intp(2), ProvKVBytesInUseAtAdmit: i64p(1 << 30), ProvCancelStage: "",
		EngQueueWaitNS: i64p(1000), EngFirstTokenNS: i64p(150000000), EngPromptComputedNS: i64p(120000000),
		EngPrefillChunks: intp(3), EngDecodeSteps: intp(39), EngMTPAccepted: nil, EngFinishReason: "stop",
		ProviderProfile: json.RawMessage(`{"version":1,"engine":{"steps":39}}`), ProviderProfileValid: true,
		ProviderProfileInvalidReason: "", ProviderProfileConsistent: boolp(true),

		CreatedAt: at,
	}
}

func fullSnapshot(providerID, model string, at time.Time) store.FleetSnapshotRow {
	return store.FleetSnapshotRow{
		SampledAt: at, ProviderID: providerID, Model: model, EligibilityReason: "eligible", SlotState: "running",
		NumRunning: 2, NumWaiting: 1, QueuedPrefillTokens: 4096, PartialPrefillRows: 1,
		ActiveTokenBudgetUsed: 20000, ActiveTokenBudgetMax: 65536, KVBytesInUse: 3 << 30, KVBytesCapacity: 8 << 30,
		ObservedDecodeTPS: 42.5, ObservedPrefillTPS: 1800.25, IsolatedPrefillTPS: 2200, EWMAInitialized: boolp(true),
		MaxConcurrency: 4, PendingCount: 3, EffectiveCap: 4,
		CooldownActive: false, BreakerOpen: false, ClampActive: true, Ejected: false,
		GPUMemoryActiveGB: 30.5, GPUMemoryPeakGB: 33.25, FreeForLoadGB: ptrF64(12), MemoryPressure: 0.6, CPUUsage: 0.2,
		ThermalState: "nominal", LowPowerMode: boolp(false), MemoryPressureLevel: "normal",
		StepsExecuted: 100000, StepWallNSTotal: 5e12, DecodeRowsTotal: 250000, PrefillTokensTotal: 9000000,
		MTPRoundsTotal: 5000, MTPProposedTotal: 10000, MTPAcceptedTotal: 7000,
		HeartbeatAgeMs: 1200, WedgeSuspected: false, EvalInFlightMs: 0,
		RequestsServed: 1234, TokensGenerated: 456789, CancellationsReceived: 12, CancellationsBeforeOutput: 3,
		CancellationsPartialComplete: 9, GenerationErrorsAfterOutput: 1, ChunkEncryptionErrors: 0,
		StreamClosedWithoutTerminal: 2, CancelDuringModelLoad: 0, UsageGaps: 1,
		CancelStagePreAcceptTotal: 1, CancelStagePreEngineTotal: 2, CancelStagePrefillTotal: 3, CancelStageDecodeTotal: 4,
		CancelStagePostTerminalTotal: 2, TokensAfterCancelTotal: 40, CancelAbortNSSum: 9e9,
		ProviderVersion: "0.8.13", ModelVision: true, TemplateRenderOK: boolp(true),
	}
}

func coordinatorSnapshot(at time.Time) store.FleetSnapshotRow {
	return store.FleetSnapshotRow{
		SampledAt: at, ProviderID: "coordinator", EligibilityReason: "", SlotState: "",
		QueueDepthTotal: 5, QueueDepthByModel: json.RawMessage(`{"qwen3-30b": 3, "gemma4-26b": 2}`),
		InflightRequests: 17, ReserveLockWaitP95US: 850, ProfileSinkDepth: 12, ProfileSinkDroppedTotal: 0,
		RouteSinkDroppedTotal: 4, UnknownRequestFramesTotal: 1, Goroutines: 412,
	}
}

func TestRequestProfileRecordHasNoFreeFormProviderBytes(t *testing.T) {
	// Contract A: the only variable-length provider-influenced fields are the
	// three JSONB long-tail documents; every other string is a closed enum or a
	// coordinator-minted id. Guard against someone adding []byte/map/any.
	for _, typ := range []reflect.Type{reflect.TypeOf(store.RequestProfileRecord{}), reflect.TypeOf(store.FleetSnapshotRow{})} {
		for i := 0; i < typ.NumField(); i++ {
			f := typ.Field(i)
			switch f.Type.Kind() {
			case reflect.Map, reflect.Interface, reflect.Array:
				t.Errorf("%s.%s has kind %s; profiler rows must be flat typed columns", typ.Name(), f.Name, f.Type.Kind())
			case reflect.Slice:
				if f.Type != reflect.TypeOf(json.RawMessage{}) {
					t.Errorf("%s.%s is a %s; only json.RawMessage slices are allowed", typ.Name(), f.Name, f.Type)
				}
			}
		}
	}
}

func TestRequestProfilesWriteOnceAndReadNewestFirst(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			base := time.Now().UTC().Truncate(time.Microsecond)
			a := fullProfile(uniqueID("req-a"), 0, base.Add(-3*time.Second))
			b := fullProfile(uniqueID("req-b"), 0, base.Add(-2*time.Second))
			c := fullProfile(uniqueID("req-c"), 1, base.Add(-1*time.Second))
			// Sparse record: nil pointers, zero counters, empty JSONB.
			c.AuthDoneUS, c.HandlerEntryUS, c.DBUS, c.TransportEstUS = nil, nil, nil, nil
			c.ReservationTTFTCeilingMs, c.DispatchBudgetMs = nil, nil
			c.AdmissionMode, c.PredictiveBypass = "", ""
			c.ShadowWouldShed, c.ProvLoadCold, c.ProviderProfileConsistent = nil, nil, nil
			c.ProvRunningAtAdmit, c.ProvWaitingAtAdmit, c.EngPrefillChunks = nil, nil, nil
			c.GateRejections, c.Candidates, c.ProviderProfile = nil, json.RawMessage{}, nil
			c.DBCalls, c.BodyBytes, c.RunnerUpCostMs, c.Winning = 0, 0, 0, false
			c.ProviderProfileValid = false

			// Intra-call duplicate of a with different content: must be ignored.
			dupA := fullProfile(a.RequestID, a.Attempt, base)
			dupA.FinalStatus = "overwritten?"
			if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{a, nil, b, c, dupA}); err != nil {
				t.Fatalf("RecordRequestProfiles: %v", err)
			}
			// Cross-call duplicate: also ignored, no error.
			if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{dupA}); err != nil {
				t.Fatalf("RecordRequestProfiles(dup): %v", err)
			}
			if err := s.RecordRequestProfiles(nil); err != nil {
				t.Fatalf("RecordRequestProfiles(nil): %v", err)
			}

			got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{})
			if len(got) != 3 {
				t.Fatalf("RequestProfilesSinceFiltered(zero) = %d rows, want 3", len(got))
			}
			wantOrder := []*store.RequestProfileRecord{c, b, a}
			for i, want := range wantOrder {
				g := normalizeProfile(t, got[i])
				w := normalizeProfile(t, *want)
				if !reflect.DeepEqual(g, w) {
					t.Errorf("row %d (%s) mismatch:\n got %+v\nwant %+v", i, want.RequestID, g, w)
				}
			}
			// The duplicate never overwrote a.
			if got[2].FinalStatus != "ok" {
				t.Fatalf("duplicate overwrote row: final_status = %q", got[2].FinalStatus)
			}
			// Pointer/NULL semantics on the sparse row.
			sparse := got[0]
			if sparse.AuthDoneUS != nil || sparse.ShadowWouldShed != nil || sparse.ProvRunningAtAdmit != nil || sparse.EngPrefillChunks != nil {
				t.Fatal("nil pointer field came back non-nil")
			}
			if sparse.GateRejections != nil || sparse.Candidates != nil || sparse.ProviderProfile != nil {
				t.Fatalf("empty JSONB came back non-nil: %q %q %q", sparse.GateRejections, sparse.Candidates, sparse.ProviderProfile)
			}
			if sparse.DBCalls != 0 || sparse.BodyBytes != 0 || sparse.RunnerUpCostMs != 0 || sparse.Winning {
				t.Fatal("zero non-pointer field came back non-zero")
			}
			// Pointer-to-zero on the full row stays a non-nil zero.
			full := got[1]
			if full.HandlerEntryUS == nil || *full.HandlerEntryUS != 0 || full.DBUS == nil || *full.DBUS != 0 {
				t.Fatalf("pointer-to-zero lost: handler_entry_us=%v db_us=%v", full.HandlerEntryUS, full.DBUS)
			}
			if full.ProvRunningAtAdmit == nil || *full.ProvRunningAtAdmit != 0 || full.ShadowWouldShed == nil || *full.ShadowWouldShed {
				t.Fatal("pointer-to-zero int/bool lost")
			}

			// since window: only c is at/after base-1s.
			if recent := s.RequestProfilesSinceFiltered(base.Add(-time.Second), store.RequestProfileFilter{}); len(recent) != 1 || recent[0].RequestID != c.RequestID {
				t.Fatalf("RequestProfilesSinceFiltered(window) = %d rows (%v), want just c", len(recent), recent)
			}
		})
	}
}

func TestFleetSnapshotsRoundTrip(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			tick1 := time.Now().UTC().Truncate(time.Microsecond).Add(-2 * time.Minute)
			tick2 := tick1.Add(time.Minute)
			p1 := fullSnapshot(uniqueID("prov"), "qwen3-30b", tick1)
			p2 := fullSnapshot(uniqueID("prov"), "gemma4-26b", tick1)
			p2.EWMAInitialized, p2.LowPowerMode = nil, nil // nil pointers → NULL
			p2.SlotState, p2.ObservedDecodeTPS = "idle", 0
			// Capability columns: an unreported render opinion (NULL), no vision,
			// and the fold's sentinel for an unparseable version.
			p2.TemplateRenderOK, p2.ModelVision, p2.ProviderVersion = nil, false, "invalid"
			coord := coordinatorSnapshot(tick1)
			if err := s.RecordFleetSnapshots([]store.FleetSnapshotRow{p1, p2, coord}); err != nil {
				t.Fatalf("RecordFleetSnapshots: %v", err)
			}
			if err := s.RecordFleetSnapshots(nil); err != nil {
				t.Fatalf("RecordFleetSnapshots(nil): %v", err)
			}
			p3 := fullSnapshot(p1.ProviderID, "qwen3-30b", tick2)
			p3.TemplateRenderOK = boolp(false) // explicit false survives (the exclusion signal)
			coord2 := coordinatorSnapshot(tick2)
			coord2.QueueDepthByModel = nil
			if err := s.RecordFleetSnapshots([]store.FleetSnapshotRow{p3, coord2}); err != nil {
				t.Fatalf("RecordFleetSnapshots(tick2): %v", err)
			}

			got := s.FleetSnapshotsSince(time.Time{})
			if len(got) != 5 {
				t.Fatalf("FleetSnapshotsSince(zero) = %d rows, want 5", len(got))
			}
			want := []store.FleetSnapshotRow{coord2, p3, coord, p2, p1} // newest tick first, reverse insertion within a tick
			for i := range want {
				g, w := normalizeSnapshot(t, got[i]), normalizeSnapshot(t, want[i])
				if !reflect.DeepEqual(g, w) {
					t.Errorf("row %d mismatch:\n got %+v\nwant %+v", i, g, w)
				}
			}
			if got[0].QueueDepthByModel != nil {
				t.Fatalf("nil JSONB came back %q", got[0].QueueDepthByModel)
			}
			if got[3].EWMAInitialized != nil || got[3].LowPowerMode != nil {
				t.Fatal("nil *bool came back non-nil")
			}
			if got[4].EWMAInitialized == nil || !*got[4].EWMAInitialized || got[4].LowPowerMode == nil || *got[4].LowPowerMode {
				t.Fatal("*bool values lost")
			}
			// Capability columns: p1 full, p2 NULL render opinion + sentinel
			// version, p3 explicit false, coordinator rows zero/NULL.
			if got[4].ProviderVersion != "0.8.13" || !got[4].ModelVision || got[4].TemplateRenderOK == nil || !*got[4].TemplateRenderOK {
				t.Fatalf("p1 capability columns lost: version=%q vision=%v render_ok=%v", got[4].ProviderVersion, got[4].ModelVision, got[4].TemplateRenderOK)
			}
			if got[3].ProviderVersion != "invalid" || got[3].ModelVision || got[3].TemplateRenderOK != nil {
				t.Fatalf("p2 capability columns: version=%q vision=%v render_ok=%v, want invalid/false/nil", got[3].ProviderVersion, got[3].ModelVision, got[3].TemplateRenderOK)
			}
			if got[1].TemplateRenderOK == nil || *got[1].TemplateRenderOK {
				t.Fatalf("p3 explicit template_render_ok=false lost: %v", got[1].TemplateRenderOK)
			}
			for _, i := range []int{0, 2} {
				if got[i].ProviderVersion != "" || got[i].ModelVision || got[i].TemplateRenderOK != nil {
					t.Fatalf("coordinator row %d carries capability columns: %+v", i, got[i])
				}
			}
			if recent := s.FleetSnapshotsSince(tick2); len(recent) != 2 {
				t.Fatalf("FleetSnapshotsSince(tick2) = %d rows, want 2", len(recent))
			}
		})
	}
}

func TestPruneTelemetryDeletesOnlyOlderRows(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().UTC().Truncate(time.Microsecond)
			old := now.Add(-2 * time.Hour)
			cutoff := now.Add(-time.Hour)

			profiles := make([]*store.RequestProfileRecord, 0, 15)
			for i := 0; i < 12; i++ {
				profiles = append(profiles, fullProfile(uniqueID("old"), 0, old.Add(time.Duration(i)*time.Second)))
			}
			for i := 0; i < 3; i++ {
				profiles = append(profiles, fullProfile(uniqueID("new"), 0, now.Add(time.Duration(i)*time.Second)))
			}
			if err := s.RecordRequestProfiles(profiles); err != nil {
				t.Fatalf("RecordRequestProfiles: %v", err)
			}
			snaps := []store.FleetSnapshotRow{
				fullSnapshot("p", "m", old), fullSnapshot("p", "m", old.Add(time.Minute)),
				fullSnapshot("p", "m", old.Add(2*time.Minute)), coordinatorSnapshot(old),
				fullSnapshot("p", "m", now), coordinatorSnapshot(now),
			}
			if err := s.RecordFleetSnapshots(snaps); err != nil {
				t.Fatalf("RecordFleetSnapshots: %v", err)
			}

			deleted, err := s.PruneTelemetry(context.Background(), cutoff, cutoff, 5)
			if err != nil {
				t.Fatalf("PruneTelemetry: %v", err)
			}
			if deleted != 16 {
				t.Fatalf("PruneTelemetry deleted %d rows, want 16", deleted)
			}
			remaining := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{})
			if len(remaining) != 3 {
				t.Fatalf("%d profiles remain, want 3", len(remaining))
			}
			for _, r := range remaining {
				if r.CreatedAt.Before(cutoff) {
					t.Fatalf("old profile survived: %s created %s", r.RequestID, r.CreatedAt)
				}
			}
			if rest := s.FleetSnapshotsSince(time.Time{}); len(rest) != 2 {
				t.Fatalf("%d snapshots remain, want 2", len(rest))
			}
			// Idempotent: nothing left below the cutoff.
			if deleted, err = s.PruneTelemetry(context.Background(), cutoff, cutoff, 5); err != nil || deleted != 0 {
				t.Fatalf("second PruneTelemetry = (%d, %v), want (0, nil)", deleted, err)
			}
			// Zero cutoffs prune nothing.
			if deleted, err = s.PruneTelemetry(context.Background(), time.Time{}, time.Time{}, 5); err != nil || deleted != 0 {
				t.Fatalf("zero-cutoff PruneTelemetry = (%d, %v), want (0, nil)", deleted, err)
			}
			// A pruned (request_id, attempt) can be written again.
			if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{profiles[0]}); err != nil {
				t.Fatalf("re-insert pruned profile: %v", err)
			}
			if got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{}); len(got) != 4 {
				t.Fatalf("after re-insert %d profiles, want 4", len(got))
			}
		})
	}
}

func TestPostgresRecordRequestProfilesLargeBatchUsesAllShapes(t *testing.T) {
	s := testPostgresStore(t)
	base := time.Now().UTC().Truncate(time.Microsecond)
	records := make([]*store.RequestProfileRecord, 0, 70) // 64 + 6 → shapes 64 and 8
	for i := 0; i < 70; i++ {
		records = append(records, fullProfile(uniqueID("bulk"), i%3, base.Add(time.Duration(i)*time.Millisecond)))
	}
	if err := s.RecordRequestProfiles(records); err != nil {
		t.Fatalf("RecordRequestProfiles(70): %v", err)
	}
	got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{})
	if len(got) != 70 {
		t.Fatalf("read back %d rows, want 70", len(got))
	}
	for i := range got {
		if want := records[69-i].RequestID; got[i].RequestID != want {
			t.Fatalf("row %d = %s, want %s (newest first)", i, got[i].RequestID, want)
		}
	}
}

func ptrF64(v float64) *float64 { return &v }

// TestRequestProfilesSinceFilteredAppliesPredicatesBeforeTheCap pins the admin
// browse/export contract: a matching row older than the newest
// maxTelemetryReadRows rows is still returned when a filter is given.
func TestRequestProfilesSinceFilteredAppliesPredicatesBeforeTheCap(t *testing.T) {
	s := memory.NewMemory(store.Config{})
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	old := &store.RequestProfileRecord{CoordRequestID: "coord-old", RequestID: "req-old", ProviderID: "prov-old", Model: "m", PublicModel: "alias", FinalStatus: "error", CreatedAt: base}
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{old}); err != nil {
		t.Fatal(err)
	}
	batch := make([]*store.RequestProfileRecord, 0, 512)
	for i := 0; i < shared.MaxTelemetryReadRows; i++ {
		batch = append(batch, &store.RequestProfileRecord{CoordRequestID: "coord-new", RequestID: "req-new", Attempt: i, ProviderID: "prov-new", Model: "m", FinalStatus: "success", CreatedAt: base.Add(time.Duration(i+1) * time.Millisecond)})
		if len(batch) == 512 {
			if err := s.RecordRequestProfiles(batch); err != nil {
				t.Fatal(err)
			}
			batch = batch[:0]
		}
	}
	if len(batch) > 0 {
		if err := s.RecordRequestProfiles(batch); err != nil {
			t.Fatal(err)
		}
	}
	if got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{}); len(got) != shared.MaxTelemetryReadRows || got[len(got)-1].ProviderID == "prov-old" {
		t.Fatalf("unfiltered read must be capped to the newest rows (got %d, last=%s)", len(got), got[len(got)-1].ProviderID)
	}
	for name, f := range map[string]store.RequestProfileFilter{
		"provider":      {ProviderID: "prov-old"},
		"model alias":   {Model: "alias"},
		"final_status":  {FinalStatus: "error"},
		"coord request": {CoordRequestID: "coord-old"},
	} {
		got := s.RequestProfilesSinceFiltered(time.Time{}, f)
		if len(got) != 1 || got[0].RequestID != "req-old" {
			t.Fatalf("filter %s returned %d rows (want the one old row): %+v", name, len(got), got)
		}
	}
	if got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{Model: "m", FinalStatus: "success"}); len(got) != shared.MaxTelemetryReadRows {
		t.Fatalf("combined filter = %d rows, want the capped %d", len(got), shared.MaxTelemetryReadRows)
	}
}

// TestRequestProfilesSinceFilteredPostgresPredicates runs the filtered read
// against a real database so the WHERE clause (provider, model-or-alias,
// final_status, coord_request_id) is exercised, not just the memory matcher.
func TestRequestProfilesSinceFilteredPostgresPredicates(t *testing.T) {
	s := testPostgresStore(t)
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	rows := []*store.RequestProfileRecord{
		{CoordRequestID: "coord-x", RequestID: "req-x", ProviderID: "prov-a", Model: "m1", PublicModel: "alias-1", FinalStatus: "success", CreatedAt: base},
		{CoordRequestID: "coord-y", RequestID: "req-y", ProviderID: "prov-b", Model: "m2", PublicModel: "alias-2", FinalStatus: "error", CreatedAt: base.Add(time.Second)},
		{CoordRequestID: "coord-z", RequestID: "req-z", ProviderID: "prov-a", Model: "m2", PublicModel: "alias-2", FinalStatus: "success", CreatedAt: base.Add(2 * time.Second)},
	}
	if err := s.RecordRequestProfiles(rows); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		f    store.RequestProfileFilter
		want []string
	}{
		"provider":      {store.RequestProfileFilter{ProviderID: "prov-a"}, []string{"req-z", "req-x"}},
		"model":         {store.RequestProfileFilter{Model: "m2"}, []string{"req-z", "req-y"}},
		"alias":         {store.RequestProfileFilter{Model: "alias-1"}, []string{"req-x"}},
		"status":        {store.RequestProfileFilter{FinalStatus: "error"}, []string{"req-y"}},
		"coord":         {store.RequestProfileFilter{CoordRequestID: "coord-z"}, []string{"req-z"}},
		"combined":      {store.RequestProfileFilter{ProviderID: "prov-a", Model: "m2"}, []string{"req-z"}},
		"none-match":    {store.RequestProfileFilter{ProviderID: "prov-a", FinalStatus: "error"}, nil},
		"empty = since": {store.RequestProfileFilter{}, []string{"req-z", "req-y", "req-x"}},
	}
	for name, tc := range cases {
		got := s.RequestProfilesSinceFiltered(time.Time{}, tc.f)
		ids := make([]string, 0, len(got))
		for _, r := range got {
			ids = append(ids, r.RequestID)
		}
		if strings.Join(ids, ",") != strings.Join(tc.want, ",") {
			t.Fatalf("%s: got %v, want %v", name, ids, tc.want)
		}
	}
}
