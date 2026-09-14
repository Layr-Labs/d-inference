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

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/testfixture"
	startupschema "github.com/eigeninference/d-inference/coordinator/store/postgres/schema"
)

func TestRequestProfileColumnsStayAligned(t *testing.T) {
	var r contracts.RequestProfileRecord
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
		if !strings.Contains(startupschema.RequestProfilesTableDDL, "\n\t\t\t"+col+" ") {
			t.Errorf("request_profiles DDL lacks column %q", col)
		}
	}
	if want := reflect.TypeOf(r).NumField(); len(requestProfileColumns) != want {
		t.Fatalf("request_profiles has %d columns but RequestProfileRecord has %d fields", len(requestProfileColumns), want)
	}

	var f contracts.FleetSnapshotRow
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
		if !strings.Contains(startupschema.FleetSnapshotsTableDDL, "\n\t\t\t"+col+" ") {
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

func TestRequestProfileRecordHasNoFreeFormProviderBytes(t *testing.T) {
	// Contract A: the only variable-length provider-influenced fields are the
	// three JSONB long-tail documents; every other string is a closed enum or a
	// coordinator-minted id. Guard against someone adding []byte/map/any.
	for _, typ := range []reflect.Type{reflect.TypeOf(contracts.RequestProfileRecord{}), reflect.TypeOf(contracts.FleetSnapshotRow{})} {
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

func TestRequestProfilesWriteOnceAndReadNewestFirst(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			base := time.Now().UTC().Truncate(time.Microsecond)
			a := testfixture.FullProfile(uniqueID("req-a"), 0, base.Add(-3*time.Second))
			b := testfixture.FullProfile(uniqueID("req-b"), 0, base.Add(-2*time.Second))
			c := testfixture.FullProfile(uniqueID("req-c"), 1, base.Add(-1*time.Second))
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
			dupA := testfixture.FullProfile(a.RequestID, a.Attempt, base)
			dupA.FinalStatus = "overwritten?"
			if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{a, nil, b, c, dupA}); err != nil {
				t.Fatalf("RecordRequestProfiles: %v", err)
			}
			// Cross-call duplicate: also ignored, no error.
			if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{dupA}); err != nil {
				t.Fatalf("RecordRequestProfiles(dup): %v", err)
			}
			if err := s.RecordRequestProfiles(nil); err != nil {
				t.Fatalf("RecordRequestProfiles(nil): %v", err)
			}

			got := s.RequestProfilesSince(time.Time{})
			if len(got) != 3 {
				t.Fatalf("RequestProfilesSince(zero) = %d rows, want 3", len(got))
			}
			wantOrder := []*contracts.RequestProfileRecord{c, b, a}
			for i, want := range wantOrder {
				g := testfixture.NormalizeProfile(t, got[i])
				w := testfixture.NormalizeProfile(t, *want)
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
			if recent := s.RequestProfilesSince(base.Add(-time.Second)); len(recent) != 1 || recent[0].RequestID != c.RequestID {
				t.Fatalf("RequestProfilesSince(window) = %d rows (%v), want just c", len(recent), recent)
			}
		})
	}
}

func TestFleetSnapshotsRoundTrip(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			tick1 := time.Now().UTC().Truncate(time.Microsecond).Add(-2 * time.Minute)
			tick2 := tick1.Add(time.Minute)
			p1 := testfixture.FullSnapshot(uniqueID("prov"), "qwen3-30b", tick1)
			p2 := testfixture.FullSnapshot(uniqueID("prov"), "gemma4-26b", tick1)
			p2.EWMAInitialized, p2.LowPowerMode = nil, nil // nil pointers → NULL
			p2.SlotState, p2.ObservedDecodeTPS = "idle", 0
			// Capability columns: an unreported render opinion (NULL), no vision,
			// and the fold's sentinel for an unparseable version.
			p2.TemplateRenderOK, p2.ModelVision, p2.ProviderVersion = nil, false, "invalid"
			coord := testfixture.CoordinatorSnapshot(tick1)
			if err := s.RecordFleetSnapshots([]contracts.FleetSnapshotRow{p1, p2, coord}); err != nil {
				t.Fatalf("RecordFleetSnapshots: %v", err)
			}
			if err := s.RecordFleetSnapshots(nil); err != nil {
				t.Fatalf("RecordFleetSnapshots(nil): %v", err)
			}
			p3 := testfixture.FullSnapshot(p1.ProviderID, "qwen3-30b", tick2)
			p3.TemplateRenderOK = testfixture.Bool(false) // explicit false survives (the exclusion signal)
			coord2 := testfixture.CoordinatorSnapshot(tick2)
			coord2.QueueDepthByModel = nil
			if err := s.RecordFleetSnapshots([]contracts.FleetSnapshotRow{p3, coord2}); err != nil {
				t.Fatalf("RecordFleetSnapshots(tick2): %v", err)
			}

			got := s.FleetSnapshotsSince(time.Time{})
			if len(got) != 5 {
				t.Fatalf("FleetSnapshotsSince(zero) = %d rows, want 5", len(got))
			}
			want := []contracts.FleetSnapshotRow{coord2, p3, coord, p2, p1} // newest tick first, reverse insertion within a tick
			for i := range want {
				g, w := testfixture.NormalizeSnapshot(t, got[i]), testfixture.NormalizeSnapshot(t, want[i])
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

			profiles := make([]*contracts.RequestProfileRecord, 0, 15)
			for i := 0; i < 12; i++ {
				profiles = append(profiles, testfixture.FullProfile(uniqueID("old"), 0, old.Add(time.Duration(i)*time.Second)))
			}
			for i := 0; i < 3; i++ {
				profiles = append(profiles, testfixture.FullProfile(uniqueID("new"), 0, now.Add(time.Duration(i)*time.Second)))
			}
			if err := s.RecordRequestProfiles(profiles); err != nil {
				t.Fatalf("RecordRequestProfiles: %v", err)
			}
			snaps := []contracts.FleetSnapshotRow{
				testfixture.FullSnapshot("p", "m", old), testfixture.FullSnapshot("p", "m", old.Add(time.Minute)),
				testfixture.FullSnapshot("p", "m", old.Add(2*time.Minute)), testfixture.CoordinatorSnapshot(old),
				testfixture.FullSnapshot("p", "m", now), testfixture.CoordinatorSnapshot(now),
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
			remaining := s.RequestProfilesSince(time.Time{})
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
			if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{profiles[0]}); err != nil {
				t.Fatalf("re-insert pruned profile: %v", err)
			}
			if got := s.RequestProfilesSince(time.Time{}); len(got) != 4 {
				t.Fatalf("after re-insert %d profiles, want 4", len(got))
			}
		})
	}
}

func TestPostgresRecordRequestProfilesLargeBatchUsesAllShapes(t *testing.T) {
	s := testPostgresStore(t)
	base := time.Now().UTC().Truncate(time.Microsecond)
	records := make([]*contracts.RequestProfileRecord, 0, 70) // 64 + 6 → shapes 64 and 8
	for i := 0; i < 70; i++ {
		records = append(records, testfixture.FullProfile(uniqueID("bulk"), i%3, base.Add(time.Duration(i)*time.Millisecond)))
	}
	if err := s.RecordRequestProfiles(records); err != nil {
		t.Fatalf("RecordRequestProfiles(70): %v", err)
	}
	got := s.RequestProfilesSince(time.Time{})
	if len(got) != 70 {
		t.Fatalf("read back %d rows, want 70", len(got))
	}
	for i := range got {
		if want := records[69-i].RequestID; got[i].RequestID != want {
			t.Fatalf("row %d = %s, want %s (newest first)", i, got[i].RequestID, want)
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
	records := make([]*contracts.RequestProfileRecord, 0, 12)
	for i := 0; i < 12; i++ {
		records = append(records, testfixture.FullProfile(uniqueID("old"), 0, old.Add(time.Duration(i)*time.Second)))
	}
	if err := s.RecordRequestProfiles(records); err != nil {
		t.Fatalf("RecordRequestProfiles: %v", err)
	}
	if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{testfixture.FullProfile(uniqueID("new"), 0, now)}); err != nil {
		t.Fatalf("RecordRequestProfiles(new): %v", err)
	}

	deleted, rounds, err := s.pruneTelemetryTable(ctx, requestProfilesTable, cutoff, 5)
	if err != nil {
		t.Fatalf("pruneTelemetryTable: %v", err)
	}
	if deleted != 12 || rounds != 3 {
		t.Fatalf("pruneTelemetryTable = (%d deleted, %d rounds), want (12, 3)", deleted, rounds)
	}
	if got := s.RequestProfilesSince(time.Time{}); len(got) != 1 {
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
	if got := s.RequestProfilesSince(time.Time{}); len(got) != 1 {
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
	p := testfixture.FullProfile(uniqueID("wf"), 0, at)
	if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{p}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordInferenceRoute(&contracts.InferenceRouteRecord{RequestID: p.RequestID, Attempt: 0, ProviderID: p.ProviderID, CostMs: 800.5, CreatedAt: at}); err != nil {
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
	orphan := testfixture.FullProfile(uniqueID("orphan"), 0, at)
	if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{orphan}); err != nil {
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

// TestRequestProfilesSinceFilteredPostgresPredicates runs the filtered read
// against a real database so the WHERE clause (provider, model-or-alias,
// final_status, coord_request_id) is exercised, not just the memory matcher.
func TestRequestProfilesSinceFilteredPostgresPredicates(t *testing.T) {
	s := testPostgresStore(t)
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	rows := []*contracts.RequestProfileRecord{
		{CoordRequestID: "coord-x", RequestID: "req-x", ProviderID: "prov-a", Model: "m1", PublicModel: "alias-1", FinalStatus: "success", CreatedAt: base},
		{CoordRequestID: "coord-y", RequestID: "req-y", ProviderID: "prov-b", Model: "m2", PublicModel: "alias-2", FinalStatus: "error", CreatedAt: base.Add(time.Second)},
		{CoordRequestID: "coord-z", RequestID: "req-z", ProviderID: "prov-a", Model: "m2", PublicModel: "alias-2", FinalStatus: "success", CreatedAt: base.Add(2 * time.Second)},
	}
	if err := s.RecordRequestProfiles(rows); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		f    contracts.RequestProfileFilter
		want []string
	}{
		"provider":      {contracts.RequestProfileFilter{ProviderID: "prov-a"}, []string{"req-z", "req-x"}},
		"model":         {contracts.RequestProfileFilter{Model: "m2"}, []string{"req-z", "req-y"}},
		"alias":         {contracts.RequestProfileFilter{Model: "alias-1"}, []string{"req-x"}},
		"status":        {contracts.RequestProfileFilter{FinalStatus: "error"}, []string{"req-y"}},
		"coord":         {contracts.RequestProfileFilter{CoordRequestID: "coord-z"}, []string{"req-z"}},
		"combined":      {contracts.RequestProfileFilter{ProviderID: "prov-a", Model: "m2"}, []string{"req-z"}},
		"none-match":    {contracts.RequestProfileFilter{ProviderID: "prov-a", FinalStatus: "error"}, nil},
		"empty = since": {contracts.RequestProfileFilter{}, []string{"req-z", "req-y", "req-x"}},
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
