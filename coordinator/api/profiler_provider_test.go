package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// fixtureReceivedAt matches wall_ms in the shared fixture (2026-09-02T00:00:00.123Z).
var fixtureReceivedAt = time.UnixMilli(1788307200123)

// fixtureProfile returns the compact `profile` bytes of one fixture frame.
func fixtureProfile(t *testing.T, frame string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "protocol", "testdata", "profiler_wire_fixture.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var frames map[string]json.RawMessage
	if err := json.Unmarshal(data, &frames); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	var msg struct {
		Profile json.RawMessage `json:"profile"`
	}
	if err := json.Unmarshal(frames[frame], &msg); err != nil {
		t.Fatalf("frame %q: %v", frame, err)
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, msg.Profile); err != nil {
		t.Fatalf("compact: %v", err)
	}
	return buf.Bytes()
}

// profileKeySet returns every key in raw, recursively, as "a.b" paths.
func profileKeySet(t *testing.T, raw []byte) map[string]bool {
	t.Helper()
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		t.Fatalf("not an object: %v", err)
	}
	keys := map[string]bool{}
	var walk func(prefix string, m map[string]json.RawMessage)
	walk = func(prefix string, m map[string]json.RawMessage) {
		for k, v := range m {
			keys[prefix+k] = true
			var nested map[string]json.RawMessage
			if len(v) > 0 && v[0] == '{' && json.Unmarshal(v, &nested) == nil {
				walk(prefix+k+".", nested)
			}
		}
	}
	walk("", obj)
	return keys
}

func newProviderProfileTestServer(logs io.Writer) *Server {
	if logs == nil {
		logs = io.Discard
	}
	return &Server{logger: slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))}
}

func TestDecodeInferenceProfileFixtureIsValidAndLossless(t *testing.T) {
	for _, frame := range []string{"inference_complete_full", "inference_error_minimal"} {
		t.Run(frame, func(t *testing.T) {
			raw := fixtureProfile(t, frame)
			stored, valid, reason, folded := decodeInferenceProfile(raw, fixtureReceivedAt)
			if !valid || reason != "" || folded || stored == nil {
				t.Fatalf("valid=%v reason=%q folded=%v stored=%v", valid, reason, folded, stored != nil)
			}
			encoded, err := json.Marshal(stored)
			if err != nil {
				t.Fatalf("marshal stored: %v", err)
			}
			got, want := profileKeySet(t, encoded), profileKeySet(t, raw)
			if !reflect.DeepEqual(got, want) {
				missing, extra := []string{}, []string{}
				for k := range want {
					if !got[k] {
						missing = append(missing, k)
					}
				}
				for k := range got {
					if !want[k] {
						extra = append(extra, k)
					}
				}
				t.Fatalf("stored key set differs from fixture: missing=%v extra=%v", missing, extra)
			}
			// Values, not just keys: the stored JSON must equal the fixture
			// object (same numbers, same enum strings) when both are canonical.
			var a, b any
			if err := json.Unmarshal(encoded, &a); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(raw, &b); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(a, b) {
				t.Fatalf("stored profile differs from fixture:\n got %s\nwant %s", encoded, raw)
			}
		})
	}
}

// Every field the wire struct can decode must reach the stored struct: set
// every pointer/enum on protocol.InferenceProfile via reflection, round-trip,
// and compare key sets. This catches a field added to the wire struct but
// forgotten in decodeInferenceProfile, independent of fixture coverage.
func TestDecodeInferenceProfileCoversEveryWireField(t *testing.T) {
	fill := func(v reflect.Value) {
		for i := 0; i < v.NumField(); i++ {
			f := v.Field(i)
			switch f.Kind() {
			case reflect.Ptr:
				elem := reflect.New(f.Type().Elem())
				switch elem.Elem().Kind() {
				case reflect.Bool:
					elem.Elem().SetBool(true)
				case reflect.Int, reflect.Int64:
					elem.Elem().SetInt(1)
				case reflect.Struct:
					// Engine sub-object: filled by the caller.
					continue
				default:
					t.Fatalf("unexpected pointer elem %s on %s", elem.Elem().Kind(), v.Type().Field(i).Name)
				}
				f.Set(elem)
			case reflect.String:
				// Any closed value; the first constant of each enum is valid.
				switch f.Type() {
				case reflect.TypeOf(protocol.DeadlineMode("")):
					f.SetString(string(protocol.DeadlineModeProjected))
				case reflect.TypeOf(protocol.ThermalState("")):
					f.SetString(string(protocol.ThermalStateNominal))
				case reflect.TypeOf(protocol.CancelStage("")):
					f.SetString(string(protocol.CancelStageNone))
				case reflect.TypeOf(protocol.EngineFinishReason("")):
					f.SetString(string(protocol.EngineFinishStop))
				default:
					t.Fatalf("unexpected string field %s", v.Type().Field(i).Name)
				}
			default:
				t.Fatalf("unexpected field kind %s on %s", f.Kind(), v.Type().Field(i).Name)
			}
		}
	}
	var wire protocol.InferenceProfile
	fill(reflect.ValueOf(&wire).Elem())
	wire.Engine = &protocol.EngineProfile{}
	fill(reflect.ValueOf(wire.Engine).Elem())
	schema := protocol.InferenceProfileSchema
	wire.Schema = &schema
	wallMS := fixtureReceivedAt.UnixMilli()
	wire.WallMS = &wallMS

	raw, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > protocol.MaxInferenceProfileBytes {
		t.Fatalf("all-fields profile is %d bytes, over the %d cap", len(raw), protocol.MaxInferenceProfileBytes)
	}
	stored, valid, reason, folded := decodeInferenceProfile(raw, fixtureReceivedAt)
	if !valid || folded {
		t.Fatalf("all-ones profile invalid: reason=%q folded=%v", reason, folded)
	}
	encoded, err := json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	got, want := profileKeySet(t, encoded), profileKeySet(t, raw)
	if !reflect.DeepEqual(got, want) {
		missing := []string{}
		for k := range want {
			if !got[k] {
				missing = append(missing, k)
			}
		}
		t.Fatalf("decodeInferenceProfile silently drops wire fields: %v", missing)
	}
}

func TestDecodeInferenceProfileInvalidReasons(t *testing.T) {
	farWall := fixtureReceivedAt.Add(24*time.Hour + time.Second).UnixMilli()
	cases := []struct {
		name       string
		raw        string
		reason     string
		wantStored bool
	}{
		{"oversize", `{"schema":1,"pad":"` + strings.Repeat("x", protocol.MaxInferenceProfileBytes) + `"}`, profileInvalidSize, false},
		{"not json", `not json`, profileInvalidDecode, false},
		{"string numeric", `{"schema":1,"total_us":"x"}`, profileInvalidDecode, false},
		{"float count", `{"schema":1,"prompt_tokens":1.5}`, profileInvalidDecode, false},
		{"int64 overflow", `{"schema":1,"total_us":99999999999999999999}`, profileInvalidDecode, false},
		{"missing schema", `{"total_us":1}`, profileInvalidSchema, false},
		{"wrong schema", `{"schema":2,"total_us":1}`, profileInvalidSchema, false},
		{"negative us", `{"schema":1,"total_us":-1}`, profileInvalidRange, true},
		{"us over 1h", `{"schema":1,"total_us":3600000001}`, profileInvalidRange, true},
		{"count over 1e9", `{"schema":1,"prompt_tokens":1000000001}`, profileInvalidRange, true},
		{"bytes over 2^48", `{"schema":1,"bytes_emitted":281474976710657}`, profileInvalidRange, true},
		{"engine ns over 1h", `{"schema":1,"engine":{"admitted_ns":3600000000001}}`, profileInvalidRange, true},
		{"engine negative count", `{"schema":1,"engine":{"decode_steps":-5}}`, profileInvalidRange, true},
		{"wall skew", `{"schema":1,"wall_ms":` + profileTestInt(farWall) + `}`, profileInvalidRange, true},
		{"main chain", `{"schema":1,"first_delta_us":10,"last_delta_us":5}`, profileInvalidOrder, true},
		{"main chain skips absent", `{"schema":1,"dequeued_us":10,"engine_admitted_us":20,"total_us":15}`, profileInvalidOrder, true},
		{"load wait", `{"schema":1,"load_wait_start_us":10,"load_wait_end_us":5}`, profileInvalidOrder, true},
		{"prompt prep", `{"schema":1,"prompt_prep_start_us":10,"prompt_prep_end_us":5}`, profileInvalidOrder, true},
		{"cancel", `{"schema":1,"cancel_received_us":10,"cancel_aborted_us":5}`, profileInvalidOrder, true},
		{"steps", `{"schema":1,"steps_at_submit":10,"steps_at_finish":5}`, profileInvalidOrder, true},
		{"engine chain", `{"schema":1,"engine":{"admitted_ns":10,"kv_allocated_ns":5}}`, profileInvalidOrder, true},
		{"engine chain tail", `{"schema":1,"engine":{"first_token_ns":10,"finished_ns":5}}`, profileInvalidOrder, true},
		{"mtp", `{"schema":1,"engine":{"mtp_proposed":5,"mtp_accepted":10}}`, profileInvalidOrder, true},
		{"batch rows", `{"schema":1,"engine":{"batch_rows_min":10,"batch_rows_max":5}}`, profileInvalidOrder, true},
		{"step latency", `{"schema":1,"engine":{"step_latency_ns_sum":5,"step_latency_ns_max":10}}`, profileInvalidOrder, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stored, valid, reason, _ := decodeInferenceProfile([]byte(tc.raw), fixtureReceivedAt)
			if valid || reason != tc.reason {
				t.Fatalf("valid=%v reason=%q, want invalid %q", valid, reason, tc.reason)
			}
			if (stored != nil) != tc.wantStored {
				t.Fatalf("stored=%v, want %v", stored != nil, tc.wantStored)
			}
		})
	}

	// Range violations are clamped into range in the forensic copy.
	stored, _, _, _ := decodeInferenceProfile([]byte(`{"schema":1,"total_us":-1,"prompt_tokens":1000000001}`), fixtureReceivedAt)
	if *stored.TotalUS != 0 || *stored.PromptTokens != maxProfileCount {
		t.Fatalf("clamped copy = total_us %d prompt_tokens %d", *stored.TotalUS, *stored.PromptTokens)
	}

	// Boundaries are inclusive.
	edge := `{"schema":1,"total_us":3600000000,"prompt_tokens":1000000000,"bytes_emitted":281474976710656,"wall_ms":` +
		profileTestInt(fixtureReceivedAt.Add(24*time.Hour).UnixMilli()) + `,"engine":{"finished_ns":3600000000000}}`
	if _, valid, reason, _ := decodeInferenceProfile([]byte(edge), fixtureReceivedAt); !valid {
		t.Fatalf("inclusive boundary rejected: %s", reason)
	}
}

func profileTestInt(v int64) string { return strconv.FormatInt(v, 10) }

func TestDecodeInferenceProfileEnumFoldKeepsRecordValid(t *testing.T) {
	raw := `{"schema":1,"deadline_mode":"weird","thermal_state":"nominal","cancel_stage":"","engine":{"finish_reason":"zzz"}}`
	stored, valid, reason, folded := decodeInferenceProfile([]byte(raw), fixtureReceivedAt)
	if !valid || reason != "" || !folded {
		t.Fatalf("valid=%v reason=%q folded=%v", valid, reason, folded)
	}
	if stored.DeadlineMode != protocol.DeadlineModeOther || stored.Engine.FinishReason != protocol.EngineFinishOther {
		t.Fatalf("unknown enums not folded: %q %q", stored.DeadlineMode, stored.Engine.FinishReason)
	}
	if stored.ThermalState != protocol.ThermalStateNominal || stored.CancelStage != "" {
		t.Fatalf("valid/absent enums changed: %q %q", stored.ThermalState, stored.CancelStage)
	}
	encoded, _ := json.Marshal(stored)
	if bytes.Contains(encoded, []byte("weird")) || bytes.Contains(encoded, []byte("zzz")) {
		t.Fatalf("provider enum text reached the stored JSON: %s", encoded)
	}
	if bytes.Contains(encoded, []byte("cancel_stage")) {
		t.Fatalf("absent enum must stay absent, not become \"\": %s", encoded)
	}

	// Every closed value of every enum is accepted without folding.
	for _, raw := range []string{
		`{"schema":1,"deadline_mode":"none","thermal_state":"critical","cancel_stage":"post_terminal","engine":{"finish_reason":"stop_sequence"}}`,
		`{"schema":1,"deadline_mode":"other","thermal_state":"other","cancel_stage":"other","engine":{"finish_reason":"other"}}`,
	} {
		if _, valid, _, folded := decodeInferenceProfile([]byte(raw), fixtureReceivedAt); !valid || folded {
			t.Fatalf("closed enum values folded: %s", raw)
		}
	}
}

func TestApplyProviderProfileMaxClampedFillsHotColumns(t *testing.T) {
	const us, ns, count, byt = int64(3_600_000_000), int64(3_600_000_000_000), 1_000_000_000, int64(1) << 48
	raw := []byte(`{"schema":1,"wall_ms":` + profileTestInt(fixtureReceivedAt.Add(-24*time.Hour).UnixMilli()) + `,
		"dequeued_us":3600000000,"decrypted_us":3600000000,"parsed_us":3600000000,"admission_us":3600000000,
		"load_wait_start_us":3600000000,"load_wait_end_us":3600000000,"prompt_prep_start_us":3600000000,"prompt_prep_end_us":3600000000,
		"engine_submit_us":3600000000,"engine_admitted_us":3600000000,"first_delta_us":3600000000,"last_delta_us":3600000000,
		"terminal_built_us":3600000000,"terminal_sent_us":3600000000,"total_us":3600000000,"slept_us":3600000000,
		"prompt_tokens":1000000000,"frames_emitted":1000000000,"running_at_admit":1000000000,"waiting_at_admit":1000000000,
		"kv_bytes_in_use_at_admit":281474976710656,"kv_bytes_capacity":281474976710656,"load_cold":true,"cancel_stage":"decode",
		"engine":{"admitted_ns":3600000000000,"kv_allocated_ns":3600000000000,"prefill_first_launch_ns":3600000000000,
		"prompt_computed_ns":3600000000000,"first_token_ns":3600000000000,"finished_ns":3600000000000,
		"prefill_chunks":1000000000,"decode_steps":1000000000,"mtp_rounds":1000000000,"mtp_proposed":1000000000,"mtp_accepted":1000000000,
		"batch_rows_min":1000000000,"batch_rows_max":1000000000,"step_latency_ns_sum":3600000000000,"step_latency_ns_max":3600000000000,
		"finish_reason":"length"}}`)
	rec := &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt, ChunksIn: count}
	newProviderProfileTestServer(nil).applyProviderProfile(rec, nil, raw)

	if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" {
		t.Fatalf("max-clamped profile rejected: valid=%v reason=%q", rec.ProviderProfileValid, rec.ProviderProfileInvalidReason)
	}
	i64 := func(name string, p *int64, want int64) {
		t.Helper()
		if p == nil || *p != want {
			t.Fatalf("%s = %v, want %d", name, p, want)
		}
	}
	i := func(name string, p *int, want int) {
		t.Helper()
		if p == nil || *p != want {
			t.Fatalf("%s = %v, want %d", name, p, want)
		}
	}
	i64("ProvTotalUS", rec.ProvTotalUS, us)
	i64("ProvFirstDeltaUS", rec.ProvFirstDeltaUS, us)
	i64("ProvEngineSubmitUS", rec.ProvEngineSubmitUS, us)
	i64("ProvEngineAdmittedUS", rec.ProvEngineAdmittedUS, us)
	i64("ProvPromptPrepUS", rec.ProvPromptPrepUS, 0)
	i64("ProvLoadWaitUS", rec.ProvLoadWaitUS, 0)
	i64("ProvKVBytesInUseAtAdmit", rec.ProvKVBytesInUseAtAdmit, byt)
	i64("SleptUS", rec.SleptUS, us)
	i("ProvRunningAtAdmit", rec.ProvRunningAtAdmit, count)
	i("ProvWaitingAtAdmit", rec.ProvWaitingAtAdmit, count)
	if rec.ProvLoadCold == nil || !*rec.ProvLoadCold {
		t.Fatalf("ProvLoadCold = %v", rec.ProvLoadCold)
	}
	if rec.ProvCancelStage != "decode" || rec.EngFinishReason != "length" {
		t.Fatalf("enums = %q / %q", rec.ProvCancelStage, rec.EngFinishReason)
	}
	i64("EngQueueWaitNS", rec.EngQueueWaitNS, ns)
	i64("EngFirstTokenNS", rec.EngFirstTokenNS, ns)
	i64("EngPromptComputedNS", rec.EngPromptComputedNS, ns)
	i("EngPrefillChunks", rec.EngPrefillChunks, count)
	i("EngDecodeSteps", rec.EngDecodeSteps, count)
	i("EngMTPAccepted", rec.EngMTPAccepted, count)
	if rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
		t.Fatalf("frames_emitted == chunks_in should be consistent: %v", rec.ProviderProfileConsistent)
	}
	if rec.TransportEstUS != nil {
		t.Fatalf("no coordinator stamps → transport estimate must stay nil, got %d", *rec.TransportEstUS)
	}
	if len(rec.ProviderProfile) == 0 {
		t.Fatal("stored JSONB missing")
	}
}

func TestApplyProviderProfileFixtureHotColumns(t *testing.T) {
	raw := fixtureProfile(t, "inference_complete_full")
	writeDone, completeIngress := int64(1_000), int64(5_000_000)
	rec := &store.RequestProfileRecord{
		ReceivedAt: fixtureReceivedAt, ChunksIn: 147,
		WriteDoneUS: &writeDone, CompleteIngressUS: &completeIngress,
	}
	newProviderProfileTestServer(nil).applyProviderProfile(rec, nil, raw)

	if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" {
		t.Fatalf("fixture rejected: reason=%q", rec.ProviderProfileInvalidReason)
	}
	want := map[string]int64{
		"ProvTotalUS":             3982400,
		"ProvFirstDeltaUS":        412000,
		"ProvEngineSubmitUS":      39000,
		"ProvEngineAdmittedUS":    41200,
		"ProvPromptPrepUS":        38500 - 2100,
		"ProvLoadWaitUS":          1750 - 1700,
		"ProvKVBytesInUseAtAdmit": 1610612736,
		"EngQueueWaitNS":          2200000,
		"EngFirstTokenNS":         370800000,
		"EngPromptComputedNS":     361000000,
		"SleptUS":                 0,
		"TransportEstUS":          (5_000_000 - 1_000) - 3982400,
	}
	got := map[string]*int64{
		"ProvTotalUS": rec.ProvTotalUS, "ProvFirstDeltaUS": rec.ProvFirstDeltaUS,
		"ProvEngineSubmitUS": rec.ProvEngineSubmitUS, "ProvEngineAdmittedUS": rec.ProvEngineAdmittedUS,
		"ProvPromptPrepUS": rec.ProvPromptPrepUS, "ProvLoadWaitUS": rec.ProvLoadWaitUS,
		"ProvKVBytesInUseAtAdmit": rec.ProvKVBytesInUseAtAdmit, "EngQueueWaitNS": rec.EngQueueWaitNS,
		"EngFirstTokenNS": rec.EngFirstTokenNS, "EngPromptComputedNS": rec.EngPromptComputedNS,
		"SleptUS": rec.SleptUS, "TransportEstUS": rec.TransportEstUS,
	}
	for name, w := range want {
		if p := got[name]; p == nil || *p != w {
			t.Fatalf("%s = %v, want %d", name, p, w)
		}
	}
	if *rec.ProvRunningAtAdmit != 2 || *rec.ProvWaitingAtAdmit != 0 || *rec.ProvLoadCold {
		t.Fatalf("admit posture = %d/%d cold=%v", *rec.ProvRunningAtAdmit, *rec.ProvWaitingAtAdmit, *rec.ProvLoadCold)
	}
	if *rec.EngPrefillChunks != 2 || *rec.EngDecodeSteps != 150 || *rec.EngMTPAccepted != 96 {
		t.Fatalf("engine counts = %d/%d/%d", *rec.EngPrefillChunks, *rec.EngDecodeSteps, *rec.EngMTPAccepted)
	}
	if rec.ProvCancelStage != "post_terminal" || rec.EngFinishReason != "stop" {
		t.Fatalf("enums = %q / %q", rec.ProvCancelStage, rec.EngFinishReason)
	}
	if rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
		t.Fatalf("147 frames vs 147 chunks should be consistent: %v", rec.ProviderProfileConsistent)
	}

	// Mismatched chunk count flags inconsistency but never invalidates.
	rec2 := &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt, ChunksIn: 140}
	newProviderProfileTestServer(nil).applyProviderProfile(rec2, nil, raw)
	if !rec2.ProviderProfileValid || rec2.ProviderProfileConsistent == nil || *rec2.ProviderProfileConsistent {
		t.Fatalf("valid=%v consistent=%v", rec2.ProviderProfileValid, rec2.ProviderProfileConsistent)
	}

	// The minimal error profile has no frames_emitted → flag stays NULL.
	rec3 := &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt}
	newProviderProfileTestServer(nil).applyProviderProfile(rec3, nil, fixtureProfile(t, "inference_error_minimal"))
	if !rec3.ProviderProfileValid || rec3.ProviderProfileConsistent != nil || rec3.ProvPromptPrepUS != nil || rec3.EngQueueWaitNS != nil {
		t.Fatalf("minimal profile: valid=%v consistent=%v prep=%v eng=%v",
			rec3.ProviderProfileValid, rec3.ProviderProfileConsistent, rec3.ProvPromptPrepUS, rec3.EngQueueWaitNS)
	}
	if *rec3.ProvTotalUS != 30000500 || *rec3.ProvRunningAtAdmit != 4 {
		t.Fatalf("minimal hot columns = %d / %d", *rec3.ProvTotalUS, *rec3.ProvRunningAtAdmit)
	}
}

func TestApplyProviderProfileTransportEstimateArithmetic(t *testing.T) {
	profile := []byte(`{"schema":1,"total_us":3982400}`)
	mk := func(writeDone, completeIngress *int64) *store.RequestProfileRecord {
		return &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt, WriteDoneUS: writeDone, CompleteIngressUS: completeIngress}
	}
	srv := newProviderProfileTestServer(nil)
	wd, ci := int64(1_000), int64(5_000_000)

	rec := mk(&wd, &ci)
	srv.applyProviderProfile(rec, nil, profile)
	if rec.TransportEstUS == nil || *rec.TransportEstUS != 1_016_600 {
		t.Fatalf("transport = %v, want 1016600", rec.TransportEstUS)
	}

	// Negative is allowed: it is a measurement (provider clock ran long).
	slow := []byte(`{"schema":1,"total_us":5000000}`)
	rec = mk(&wd, &ci)
	srv.applyProviderProfile(rec, nil, slow)
	if rec.TransportEstUS == nil || *rec.TransportEstUS != -1_000 {
		t.Fatalf("transport = %v, want -1000", rec.TransportEstUS)
	}

	// Any missing operand → nil.
	for name, rec := range map[string]*store.RequestProfileRecord{
		"no write_done":       mk(nil, &ci),
		"no complete_ingress": mk(&wd, nil),
	} {
		srv.applyProviderProfile(rec, nil, profile)
		if rec.TransportEstUS != nil {
			t.Fatalf("%s: transport = %d, want nil", name, *rec.TransportEstUS)
		}
	}
	rec = mk(&wd, &ci)
	srv.applyProviderProfile(rec, nil, []byte(`{"schema":1,"first_delta_us":1}`))
	if rec.TransportEstUS != nil || !rec.ProviderProfileValid {
		t.Fatalf("no total_us: transport=%v valid=%v", rec.TransportEstUS, rec.ProviderProfileValid)
	}
}

// An invalid profile sets only the validity columns: no hot columns, no
// transport estimate, and the raw bytes never reach the row or the logs. A
// range/order-flagged profile keeps its clamped JSONB (unknown keys dropped)
// for forensics; a decode failure keeps nothing.
func TestApplyProviderProfileInvalidNeverLeaksOrFillsColumns(t *testing.T) {
	wd, ci := int64(1_000), int64(5_000_000)
	for name, tc := range map[string]struct {
		raw        string
		reason     string
		wantJSONB  bool
		wantLogged string
	}{
		"order": {
			raw:       `{"schema":1,"first_delta_us":10,"last_delta_us":5,"total_us":20,"secret_note":"ORDER_LEAK_SENTINEL"}`,
			reason:    profileInvalidOrder,
			wantJSONB: true,
		},
		"range": {
			raw:       `{"schema":1,"total_us":-1,"note":"RANGE_LEAK_SENTINEL"}`,
			reason:    profileInvalidRange,
			wantJSONB: true,
		},
		"decode": {
			raw:    `{"schema":1,"total_us":"DECODE_LEAK_SENTINEL"}`,
			reason: profileInvalidDecode,
		},
		"size": {
			raw:    `{"schema":1,"pad":"SIZE_LEAK_SENTINEL` + strings.Repeat("x", protocol.MaxInferenceProfileBytes) + `"}`,
			reason: profileInvalidSize,
		},
	} {
		t.Run(name, func(t *testing.T) {
			var logs bytes.Buffer
			srv := newProviderProfileTestServer(&logs)
			rec := &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt, WriteDoneUS: &wd, CompleteIngressUS: &ci, ChunksIn: 3}
			srv.applyProviderProfile(rec, nil, []byte(tc.raw))

			if rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != tc.reason {
				t.Fatalf("valid=%v reason=%q, want %q", rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, tc.reason)
			}
			if rec.ProvTotalUS != nil || rec.ProvFirstDeltaUS != nil || rec.TransportEstUS != nil ||
				rec.SleptUS != nil || rec.ProviderProfileConsistent != nil || rec.ProvCancelStage != "" {
				t.Fatalf("invalid profile reached typed columns: %+v", rec)
			}
			if (len(rec.ProviderProfile) > 0) != tc.wantJSONB {
				t.Fatalf("stored JSONB present=%v, want %v: %s", len(rec.ProviderProfile) > 0, tc.wantJSONB, rec.ProviderProfile)
			}
			if bytes.Contains(rec.ProviderProfile, []byte("LEAK_SENTINEL")) || bytes.Contains(rec.ProviderProfile, []byte("secret_note")) {
				t.Fatalf("raw provider bytes reached the row: %s", rec.ProviderProfile)
			}
			if strings.Contains(logs.String(), "LEAK_SENTINEL") || strings.Contains(logs.String(), "total_us") {
				t.Fatalf("raw provider bytes reached the logs:\n%s", logs.String())
			}
		})
	}
}

// Nothing persisted from a provider may be a free-form string: every string
// field on the stored profile and on the heartbeat telemetry sub-objects must
// be a named closed-enum type with a Valid() method; no []byte, RawMessage,
// any, map or slice may exist. Adding such a field fails this test on purpose.
func TestStoredInferenceProfileHasNoFreeStrings(t *testing.T) {
	var walk func(path string, typ reflect.Type)
	walk = func(path string, typ reflect.Type) {
		for typ.Kind() == reflect.Ptr {
			typ = typ.Elem()
		}
		switch typ.Kind() {
		case reflect.Struct:
			for i := 0; i < typ.NumField(); i++ {
				f := typ.Field(i)
				walk(path+"."+f.Name, f.Type)
			}
		case reflect.String:
			if typ.Name() == "" || typ.PkgPath() == "" {
				t.Errorf("%s: free-form string type %s", path, typ)
				return
			}
			if _, ok := typ.MethodByName("Valid"); !ok {
				t.Errorf("%s: named string type %s has no Valid() method", path, typ)
			}
		case reflect.Bool,
			reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
			reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64,
			reflect.Float32, reflect.Float64:
			// closed by construction
		case reflect.Slice, reflect.Array, reflect.Map, reflect.Interface, reflect.Chan, reflect.Func, reflect.UnsafePointer:
			t.Errorf("%s: open-ended kind %s (%s) is not allowed in a persisted provider struct", path, typ.Kind(), typ)
		default:
			t.Errorf("%s: unexpected kind %s (%s)", path, typ.Kind(), typ)
		}
	}
	walk("StoredInferenceProfile", reflect.TypeOf(StoredInferenceProfile{}))
	walk("SlotTelemetry", reflect.TypeOf(protocol.SlotTelemetry{}))
	walk("CapacityTelemetry", reflect.TypeOf(protocol.CapacityTelemetry{}))

	// The guard itself must bite: a struct with a bare string, a RawMessage
	// and a named string without Valid() must all be reported.
	type badEnum string
	type bad struct {
		Note string
		Raw  json.RawMessage
		Kind badEnum
		Any  any
	}
	found := 0
	var probeWalk func(path string, typ reflect.Type)
	probeWalk = func(path string, typ reflect.Type) {
		for typ.Kind() == reflect.Ptr {
			typ = typ.Elem()
		}
		switch typ.Kind() {
		case reflect.Struct:
			for i := 0; i < typ.NumField(); i++ {
				probeWalk(path, typ.Field(i).Type)
			}
		case reflect.String:
			if typ.Name() == "" || typ.PkgPath() == "" {
				found++
				return
			}
			if _, ok := typ.MethodByName("Valid"); !ok {
				found++
			}
		case reflect.Slice, reflect.Interface, reflect.Map:
			found++
		}
	}
	probeWalk("bad", reflect.TypeOf(bad{}))
	if found != 4 {
		t.Fatalf("closed-struct guard found %d of 4 planted violations", found)
	}
}

// The profile's only telemetry is bounded: valid + reason tags. A malformed
// profile on a Server without DD must not panic either.
func TestApplyProviderProfileNilRecordAndNoDDAreSafe(t *testing.T) {
	srv := newProviderProfileTestServer(nil)
	srv.applyProviderProfile(nil, nil, []byte(`{"schema":1}`))
	rec := &store.RequestProfileRecord{}
	srv.applyProviderProfile(rec, nil, []byte(`{"schema":1,"deadline_mode":"x"}`))
	if !rec.ProviderProfileValid {
		t.Fatalf("zero ReceivedAt must fall back to now, not reject: %q", rec.ProviderProfileInvalidReason)
	}
}

// TestApplyProviderProfileConsistencyChecksAreIndependent pins the rule for
// provider_profile_consistent: the frames check runs only when frames_emitted
// is present, the prompt-token check only when both terminal usage and the
// profile's prompt_tokens are present; the flag is false when any present
// check fails, true when at least one ran and all passed, NULL when nothing
// could be checked. An error terminal without frames_emitted is therefore
// still judged on its prompt tokens (previously skipped entirely).
func TestApplyProviderProfileConsistencyChecksAreIndependent(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	withUsage := func(id string, prompt int) *registry.AttemptProfile {
		ap := rp.NewAttempt(id, 0, "")
		ap.SetTerminalUsage(prompt, 1)
		return ap
	}
	noUsage := rp.NewAttempt("no-usage", 0, "")
	yes, no := true, false
	cases := []struct {
		name   string
		raw    string
		ap     *registry.AttemptProfile
		chunks int
		want   *bool
	}{
		{"frames absent, tokens mismatch", `{"schema":1,"prompt_tokens":100}`, withUsage("a", 90), 0, &no},
		{"frames absent, tokens match", `{"schema":1,"prompt_tokens":100}`, withUsage("b", 100), 0, &yes},
		{"tokens absent, frames match", `{"schema":1,"frames_emitted":7}`, noUsage, 7, &yes},
		{"tokens absent, frames mismatch", `{"schema":1,"frames_emitted":7}`, noUsage, 6, &no},
		{"frames match, tokens mismatch", `{"schema":1,"frames_emitted":7,"prompt_tokens":100}`, withUsage("c", 90), 7, &no},
		{"frames mismatch, tokens match", `{"schema":1,"frames_emitted":7,"prompt_tokens":100}`, withUsage("d", 100), 6, &no},
		{"both match", `{"schema":1,"frames_emitted":7,"prompt_tokens":100}`, withUsage("e", 100), 7, &yes},
		{"nothing to check", `{"schema":1}`, withUsage("f", 100), 0, nil},
		{"profile tokens without terminal usage", `{"schema":1,"prompt_tokens":100}`, noUsage, 0, nil},
		{"profile tokens without any attempt", `{"schema":1,"prompt_tokens":100}`, nil, 0, nil},
	}
	for _, tc := range cases {
		rec := &store.RequestProfileRecord{ReceivedAt: fixtureReceivedAt, ChunksIn: tc.chunks}
		newProviderProfileTestServer(nil).applyProviderProfile(rec, tc.ap, []byte(tc.raw))
		if !rec.ProviderProfileValid {
			t.Fatalf("%s: profile rejected: %q", tc.name, rec.ProviderProfileInvalidReason)
		}
		got := rec.ProviderProfileConsistent
		switch {
		case tc.want == nil && got != nil:
			t.Errorf("%s: consistent=%v, want NULL", tc.name, *got)
		case tc.want != nil && got == nil:
			t.Errorf("%s: consistent=NULL, want %v", tc.name, *tc.want)
		case tc.want != nil && *got != *tc.want:
			t.Errorf("%s: consistent=%v, want %v", tc.name, *got, *tc.want)
		}
	}
}
