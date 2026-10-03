package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func i64p(v int64) *int64 { return &v }

func intp(v int) *int { return &v }

func boolp(v bool) *bool { return &v }

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

func TestRequestProfileColumnsStayAligned(t *testing.T) {
	var r store.RequestProfileRecord
	var a, b, c []byte
	if got, want := len(requestProfileValues(&r, time.Now())), len(requestProfileColumns); got != want {
		t.Fatalf("requestProfileValues len = %d, columns = %d", got, want)
	}
	if got, want := len(requestProfileScanTargets(&r, &a, &b, &c)), len(requestProfileColumns); got != want {
		t.Fatalf("requestProfileScanTargets len = %d, columns = %d", got, want)
	}
	seen := map[string]bool{}
	for _, col := range requestProfileColumns {
		if seen[col] {
			t.Fatalf("duplicate request_profiles column %q", col)
		}
		seen[col] = true
		if !strings.Contains(requestProfilesTableDDL, "\n\t\t\t"+col+" ") {
			t.Errorf("request_profiles DDL lacks column %q", col)
		}
	}
	if want := reflect.TypeOf(r).NumField(); len(requestProfileColumns) != want {
		t.Fatalf("request_profiles has %d columns but RequestProfileRecord has %d fields", len(requestProfileColumns), want)
	}

	var f store.FleetSnapshotRow
	var q []byte
	if got, want := len(fleetSnapshotValues(&f, time.Now())), len(fleetSnapshotColumns); got != want {
		t.Fatalf("fleetSnapshotValues len = %d, columns = %d", got, want)
	}
	if got, want := len(fleetSnapshotScanTargets(&f, &q)), len(fleetSnapshotColumns); got != want {
		t.Fatalf("fleetSnapshotScanTargets len = %d, columns = %d", got, want)
	}
	seen = map[string]bool{}
	for _, col := range fleetSnapshotColumns {
		if seen[col] {
			t.Fatalf("duplicate fleet_snapshots column %q", col)
		}
		seen[col] = true
		if !strings.Contains(fleetSnapshotsTableDDL, "\n\t\t\t"+col+" ") {
			t.Errorf("fleet_snapshots DDL lacks column %q", col)
		}
	}
	if want := reflect.TypeOf(f).NumField(); len(fleetSnapshotColumns) != want {
		t.Fatalf("fleet_snapshots has %d columns but FleetSnapshotRow has %d fields", len(fleetSnapshotColumns), want)
	}

	// Every json tag is the snake_case column of the same position.
	rt := reflect.TypeOf(r)
	for i := 0; i < rt.NumField(); i++ {
		tag := strings.Split(rt.Field(i).Tag.Get("json"), ",")[0]
		if tag != requestProfileColumns[i] {
			t.Errorf("RequestProfileRecord.%s json tag %q != column %q", rt.Field(i).Name, tag, requestProfileColumns[i])
		}
	}
	ft := reflect.TypeOf(f)
	for i := 0; i < ft.NumField(); i++ {
		tag := strings.Split(ft.Field(i).Tag.Get("json"), ",")[0]
		if tag != fleetSnapshotColumns[i] {
			t.Errorf("FleetSnapshotRow.%s json tag %q != column %q", ft.Field(i).Name, tag, fleetSnapshotColumns[i])
		}
	}
}

func TestRequestProfileInsertShapes(t *testing.T) {
	for n, want := range map[int]int{1: 1, 2: 8, 8: 8, 9: 64, 64: 64} {
		if got := profileInsertShape(n); got != want {
			t.Errorf("profileInsertShape(%d) = %d, want %d", n, got, want)
		}
	}
	for _, shape := range profileInsertShapes {
		sql := requestProfileInsertSQL(shape)
		if !strings.HasSuffix(sql, "ON CONFLICT (request_id, attempt) DO NOTHING") {
			t.Fatalf("shape %d SQL missing ON CONFLICT clause", shape)
		}
		if got := strings.Count(sql, "("); got != shape+2 { // column list + one tuple per row + conflict target
			t.Fatalf("shape %d SQL has %d '(' groups, want %d", shape, got, shape+2)
		}
		last := fmt.Sprintf("$%d)", shape*len(requestProfileColumns))
		if !strings.HasSuffix(strings.TrimSuffix(sql, " ON CONFLICT (request_id, attempt) DO NOTHING"), last) {
			t.Fatalf("shape %d SQL last placeholder != %s", shape, last)
		}
	}
}

func TestPostgresPruneTelemetryRespectsBatch(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	old := now.Add(-2 * time.Hour)
	cutoff := now.Add(-time.Hour)

	// One call → the 12 old rows occupy contiguous ids; the padded rows of the
	// same statement consume sequence values after them.
	records := make([]*store.RequestProfileRecord, 0, 12)
	for i := 0; i < 12; i++ {
		records = append(records, fullProfile(uniqueID("old"), 0, old.Add(time.Duration(i)*time.Second)))
	}
	if err := s.RecordRequestProfiles(records); err != nil {
		t.Fatalf("RecordRequestProfiles: %v", err)
	}
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{fullProfile(uniqueID("new"), 0, now)}); err != nil {
		t.Fatalf("RecordRequestProfiles(new): %v", err)
	}

	deleted, rounds, err := s.pruneTelemetryTable(ctx, requestProfilesTable, cutoff, 5)
	if err != nil {
		t.Fatalf("pruneTelemetryTable: %v", err)
	}
	if deleted != 12 || rounds != 3 {
		t.Fatalf("pruneTelemetryTable = (%d deleted, %d rounds), want (12, 3)", deleted, rounds)
	}
	if got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{}); len(got) != 1 {
		t.Fatalf("%d rows remain, want 1", len(got))
	}
	// Nothing left below the cutoff → no rounds at all.
	if deleted, rounds, err = s.pruneTelemetryTable(ctx, requestProfilesTable, cutoff, 5); err != nil || deleted != 0 || rounds != 0 {
		t.Fatalf("empty prune = (%d, %d, %v), want (0, 0, nil)", deleted, rounds, err)
	}
	if deleted, rounds, err = s.pruneTelemetryTable(ctx, fleetSnapshotsTable, cutoff, 5); err != nil || deleted != 0 || rounds != 0 {
		t.Fatalf("empty snapshot prune = (%d, %d, %v), want (0, 0, nil)", deleted, rounds, err)
	}
	// A done context stops before touching the table.
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, _, err = s.pruneTelemetryTable(cancelled, requestProfilesTable, now.Add(time.Hour), 5); err == nil {
		t.Fatal("pruneTelemetryTable with cancelled ctx returned nil error")
	}
	if got := s.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{}); len(got) != 1 {
		t.Fatalf("cancelled prune deleted rows: %d remain, want 1", len(got))
	}
}

func TestPostgresProfilerMigrationIdempotent(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	// NewPostgres already ran migrate once; a restart runs it again.
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("re-running migrate: %v", err)
	}
	for _, idx := range []string{
		"idx_request_profiles_created", "idx_request_profiles_coord", "idx_request_profiles_provider",
		"request_profiles_request_id_attempt_key",
		"idx_fleet_snapshots_sampled", "idx_fleet_snapshots_provider",
	} {
		var n int
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE indexname = $1`, idx).Scan(&n); err != nil {
			t.Fatalf("pg_indexes %s: %v", idx, err)
		}
		if n != 1 {
			t.Fatalf("index %s: found %d, want 1", idx, n)
		}
	}
	for _, table := range []string{"request_profiles", "fleet_snapshots"} {
		var opts []string
		if err := s.pool.QueryRow(ctx, `SELECT reloptions FROM pg_class WHERE relname = $1`, table).Scan(&opts); err != nil {
			t.Fatalf("reloptions %s: %v", table, err)
		}
		joined := strings.Join(opts, ",")
		if !strings.Contains(joined, "autovacuum_vacuum_scale_factor=0.02") || !strings.Contains(joined, "autovacuum_analyze_scale_factor=0.01") {
			t.Fatalf("%s reloptions = %v, want tightened autovacuum factors", table, opts)
		}
	}
}

// requestWaterfallSQL reads the manually-applied view definition.
func requestWaterfallSQL(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("migrations", "request_waterfall.sql"))
	if err != nil {
		t.Fatalf("read request_waterfall.sql: %v", err)
	}
	return string(b)
}

func TestRequestWaterfallViewListsEveryProfileColumn(t *testing.T) {
	sql := requestWaterfallSQL(t)
	body := sql[strings.Index(sql, "CREATE OR REPLACE VIEW"):]
	for _, col := range requestProfileColumns {
		if !regexp.MustCompile(`\bp\.` + col + `\b`).MatchString(body) {
			t.Errorf("request_waterfall.sql lacks p.%s", col)
		}
	}
	if !strings.Contains(body, "p.id,") {
		t.Error("request_waterfall.sql lacks p.id")
	}
	for _, forbidden := range []string{"r.*", "p.*", "consumer_key_hash", "key_id", "cache_affinity_key",
		"hardware_chip", "hardware_tier", "system_thermal_state", "slot_state", "r.provider_version", "serial"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("request_waterfall.sql exposes %q", forbidden)
		}
	}
	if !strings.Contains(sql, "dedupe_provider_earnings.sql") || !strings.Contains(sql, "BY HAND") {
		t.Error("request_waterfall.sql header must say it is applied by hand like dedupe_provider_earnings.sql")
	}

	// With a database: the statement must be valid against the migrated schema
	// and the view must join a profile to its route on (request_id, attempt).
	if os.Getenv("DATABASE_URL") == "" {
		return
	}
	s := testPostgresStore(t)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, body); err != nil {
		t.Fatalf("apply request_waterfall.sql: %v", err)
	}
	t.Cleanup(func() { _, _ = s.pool.Exec(context.Background(), "DROP VIEW IF EXISTS request_waterfall") })

	at := time.Now().UTC().Truncate(time.Microsecond)
	p := fullProfile(uniqueID("wf"), 0, at)
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{p}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordInferenceRoute(&store.InferenceRouteRecord{RequestID: p.RequestID, Attempt: 0, ProviderID: p.ProviderID, CostMs: 800.5, CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
	var costMs *float64
	var routeID *int64
	if err := s.pool.QueryRow(ctx,
		`SELECT cost_ms, route_id FROM request_waterfall WHERE request_id = $1 AND attempt = 0`, p.RequestID,
	).Scan(&costMs, &routeID); err != nil {
		t.Fatalf("query view: %v", err)
	}
	if costMs == nil || *costMs != 800.5 || routeID == nil {
		t.Fatalf("view join: cost_ms=%v route_id=%v", costMs, routeID)
	}
	// LEFT JOIN: a profile with no route row is still visible.
	orphan := fullProfile(uniqueID("orphan"), 0, at)
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{orphan}); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx,
		`SELECT cost_ms, route_id FROM request_waterfall WHERE request_id = $1`, orphan.RequestID,
	).Scan(&costMs, &routeID); err != nil {
		t.Fatalf("query view (orphan): %v", err)
	}
	if costMs != nil || routeID != nil {
		t.Fatalf("orphan profile should have NULL route columns, got cost_ms=%v route_id=%v", costMs, routeID)
	}
}

func ptrF64(v float64) *float64 { return &v }
