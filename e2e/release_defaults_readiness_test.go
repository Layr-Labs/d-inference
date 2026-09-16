package e2e

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
	"nhooyr.io/websocket"
)

// An empty Gemma assistant cache serves target-only while its verified download,
// preparation and idle swap complete. The production rollout jitter alone can
// take five minutes. Read daemon posture; an inference probe would warm the cold
// request's prefix and change what this gate measures.
func waitForReleaseDefaultReadiness(
	parent context.Context, in connectedCacheInput, expected releaseDefaultExpectation,
	running func() bool, readState func(context.Context) ([]byte, error), readSlots func() []connectedSlot,
	confirmAdmission func(context.Context, string) error,
) error {
	ctx, cancel := context.WithTimeout(parent, 10*time.Minute)
	defer cancel()
	started := time.Now()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	var last error
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("release defaults for %s not ready: %w; last observation: %v", in.Artifact.ModelID, err, last)
		}
		if !running() {
			return fmt.Errorf("provider exited while waiting for release defaults for %s; last observation: %v", in.Artifact.ModelID, last)
		}
		var raw []byte
		last = nil
		if expected.mtp == "on" {
			raw, last = readState(ctx)
		}
		if last == nil {
			slots := readSlots()
			last = validateReleaseDefaultReadiness(slots, in, expected, raw, started, time.Now())
			if last == nil && expected.mtp == "on" {
				last = confirmAdmission(ctx, slots[0].ProviderID)
				if last == nil {
					// The quote can precede heartbeat application; recheck the
					// original SSD/paged/idle gates against the applied snapshot.
					last = validateReleaseDefaultReadiness(readSlots(), in, expected, raw, started, time.Now())
				}
			}
		}
		if last == nil {
			return nil
		}
		select {
		case <-ctx.Done():
		case <-ticker.C:
		}
	}
}

func validateReleaseDefaultReadiness(
	slots []connectedSlot, in connectedCacheInput, expected releaseDefaultExpectation,
	raw []byte, started, now time.Time,
) error {
	if err := validateReleaseDefaultSlots(slots, in, expected); err != nil {
		return err
	}
	if err := releaseDefaultIdleCapacity(slots[0].Capacity, in.Artifact.ModelID); err != nil {
		return err
	}
	if expected.mtp != "on" {
		return nil // GPT-OSS still proves its expected inactivity in each request profile.
	}
	// These are the daemon's snake_case SlotPosture fields, sampled from the
	// actual bridge at each capacity refresh and written atomically to this
	// fresh provider's isolated state directory. Config and staging logs do
	// not prove the replacement is installed in the serving slot.
	var state struct {
		Schema    int     `json:"schema"`
		PID       int     `json:"pid"`
		WrittenAt float64 `json:"written_at"`
		Slots     []struct {
			Model                   string  `json:"model"`
			KVBackend               string  `json:"kv_backend"`
			KVBackendRequested      string  `json:"kv_backend_requested"`
			KVBackendFallbackReason *string `json:"kv_backend_fallback_reason"`
			MTPEnabled              bool    `json:"mtp_enabled"`
			MTPActive               bool    `json:"mtp_active"`
			MTPInactiveReason       *string `json:"mtp_inactive_reason"`
			LoadError               *string `json:"load_error"`
		} `json:"slots"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		return fmt.Errorf("read actual daemon MTP posture: %w", err)
	}
	stamp := func(t time.Time) float64 { return float64(t.UnixNano()) / float64(time.Second) }
	if state.Schema != 1 || state.PID <= 0 || state.WrittenAt < stamp(started) ||
		state.WrittenAt < stamp(now.Add(-10*time.Second)) || state.WrittenAt > stamp(now.Add(time.Second)) {
		return fmt.Errorf("fresh daemon MTP posture not yet reported: schema=%d pid=%d written_at=%f", state.Schema, state.PID, state.WrittenAt)
	}
	found := 0
	for _, slot := range state.Slots {
		if slot.Model != in.Artifact.ModelID {
			continue
		}
		found++
		if slot.KVBackend != "paged" || slot.KVBackendRequested != "auto" || slot.KVBackendFallbackReason != nil ||
			!slot.MTPEnabled || !slot.MTPActive || slot.MTPInactiveReason != nil || slot.LoadError != nil {
			posture, _ := json.Marshal(slot)
			return fmt.Errorf("actual serving slot MTP is not ready: %s", posture)
		}
	}
	if found != 1 {
		return fmt.Errorf("one actual daemon MTP slot for %s required, got %d", in.Artifact.ModelID, found)
	}
	return nil
}

func releaseDefaultIdleCapacity(capacity *protocol.BackendCapacity, model string) error {
	found := false
	if capacity != nil {
		for _, slot := range capacity.Slots {
			if slot.Model != model {
				continue
			}
			found = true
			if slot.State != "idle" || slot.NumRunning != 0 || slot.NumWaiting != 0 || slot.ActiveTokens != 0 ||
				slot.MaxConcurrency <= 0 || slot.ActiveTokenBudgetMax <= 0 {
				return fmt.Errorf("model %s is not ready for admission: state=%q running=%d waiting=%d", model, slot.State, slot.NumRunning, slot.NumWaiting)
			}
		}
	}
	if !found {
		return fmt.Errorf("model %s has no admission capacity", model)
	}
	return nil
}

// A fresh positive control quote reads the provider's live model-drain flag and
// seq-stamped published capacity without inference, a reservation or a model
// load. Await that sequence in the same registry session: an old idle heartbeat
// alongside a newly active daemon posture cannot prove the swap has reopened.
func confirmReleaseDefaultAdmission(parent context.Context, reg *registry.Registry, relay *testbed.ProviderWireRelay, providerID, model string) error {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	provider := reg.GetProvider(providerID)
	if provider == nil {
		return fmt.Errorf("release-default provider %s disconnected", providerID)
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return err
	}
	quoteID := hex.EncodeToString(id)
	raw, err := json.Marshal(protocol.CapacityProbeMessage{Type: protocol.TypeCapacityProbe, QuoteID: quoteID,
		Model: model, PromptTokensBucket: protocol.CapacityProbePromptBucketTokens, MaxOutputTokens: 1, DeadlineRemainingMS: 2000})
	if err != nil {
		return err
	}
	before, dropped := relay.Snapshot()
	if dropped != 0 {
		return fmt.Errorf("release-default capacity observation dropped frames")
	}
	if err := provider.WriteText(ctx, raw); err != nil {
		return fmt.Errorf("write release-default capacity probe: %w", err)
	}
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	last := "no matching capacity quote"
	for {
		if reg.GetProvider(providerID) != provider {
			return fmt.Errorf("release-default provider session changed during capacity probe")
		}
		events, dropped := relay.Snapshot()
		if dropped != 0 {
			return fmt.Errorf("release-default capacity observation dropped frames")
		}
		quote, err := releaseDefaultAdmissionQuote(events[len(before):], quoteID, model)
		if err != nil {
			return err
		}
		if quote != nil {
			provider.Mu().Lock()
			applied := provider.BackendCapacity != nil && provider.BackendCapacity.CapacitySeq >= quote.CapacitySeq
			idle := releaseDefaultIdleCapacity(provider.BackendCapacity, model)
			provider.Mu().Unlock()
			if applied && idle == nil {
				if reg.GetProvider(providerID) != provider {
					return fmt.Errorf("release-default provider session changed during capacity probe")
				}
				return nil
			}
			last = fmt.Sprintf("coordinator has not applied idle capacity at positive quote sequence %d: applied=%t idle=%v", quote.CapacitySeq, applied, idle)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("release-default admission not confirmed: %w; %s", ctx.Err(), last)
		case <-ticker.C:
		}
	}
}

func releaseDefaultAdmissionQuote(events []testbed.ProviderWireEvent, quoteID, model string) (*protocol.CapacityQuoteMessage, error) {
	connection := 0
	for _, event := range events {
		var id string
		if json.Unmarshal(event.Fields["quote_id"], &id) != nil || id != quoteID {
			continue
		}
		if event.Type == "capacity_probe" && event.Direction == "coordinator_to_provider" {
			var actualModel string
			if json.Unmarshal(event.Fields["model"], &actualModel) != nil || actualModel != model || event.Connection <= 0 {
				return nil, fmt.Errorf("release-default capacity probe identity differs")
			}
			connection = event.Connection
		}
		if event.Type == "capacity_quote" && event.Direction == "provider_to_coordinator" {
			if connection == 0 || event.Connection != connection {
				return nil, fmt.Errorf("release-default capacity quote arrived on a different connection")
			}
			raw, err := json.Marshal(event.Fields)
			if err != nil {
				return nil, err
			}
			var quote protocol.CapacityQuoteMessage
			if err := json.Unmarshal(raw, &quote); err != nil {
				return nil, err
			}
			if !quote.AdmissibleNow || quote.CapacitySeq == 0 || quote.RejectionReason != "" {
				return nil, fmt.Errorf("release-default admission closed: admissible=%t sequence=%d reason=%q", quote.AdmissibleNow, quote.CapacitySeq, quote.RejectionReason)
			}
			return &quote, nil
		}
	}
	return nil, nil
}

func releaseDefaultReadinessFixture(t *testing.T) (connectedCacheInput, releaseDefaultExpectation, []connectedSlot, map[string]any) {
	t.Helper()
	in := connectedCacheInput{Backend: "auto", MTPMode: "auto", CacheMode: "ssd", MaxConcurrent: 1}
	in.Artifact.ModelID = "gemma-4-26b-qat-4bit"
	in.Artifact.ModelAggregateSHA256 = "hash"
	in.Artifact.PromptContractID = "contract"
	expected, err := releaseDefaultSelection(in)
	require.NoError(t, err)
	paged := "paged"
	slots := []connectedSlot{{Model: in.Artifact.ModelID, Aggregate: "hash",
		CacheStatus: &protocol.PrefixCacheModelStatus{ModelID: in.Artifact.ModelID, Backend: "paged", State: "ready", Reason: "ready"},
		Capability:  &protocol.PrefixCacheV2Capability{Enabled: true, Ready: true, ModelID: in.Artifact.ModelID, ModelAggregateHash: "hash", PromptContractID: "contract"},
		Capacity:    &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: in.Artifact.ModelID, State: "idle", KVBackend: &paged, MaxConcurrency: 1, ActiveTokenBudgetMax: 4096}}},
	}}
	posture := map[string]any{"model": in.Artifact.ModelID, "kv_backend": "paged", "kv_backend_requested": "auto", "mtp_enabled": true, "mtp_active": true}
	return in, expected, slots, posture
}

func releaseDefaultDaemonFixture(t *testing.T, now time.Time, postures ...map[string]any) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"schema": 1, "pid": 123, "written_at": float64(now.UnixNano()) / float64(time.Second), "slots": postures})
	require.NoError(t, err)
	return raw
}

func TestReleaseDefaultReadinessWaitsForActualMTPWithoutInference(t *testing.T) {
	in, expected, slots, posture := releaseDefaultReadinessFixture(t)
	reads := 0
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := waitForReleaseDefaultReadiness(ctx, in, expected, func() bool { return true },
		func(context.Context) ([]byte, error) {
			reads++
			posture["mtp_active"] = reads >= 3
			if reads < 3 {
				posture["mtp_inactive_reason"] = "assistant_downloading"
			} else {
				delete(posture, "mtp_inactive_reason")
			}
			return releaseDefaultDaemonFixture(t, time.Now(), posture), nil
		}, func() []connectedSlot { return slots }, func(context.Context, string) error { return nil })
	require.NoError(t, err)
	require.Equal(t, 3, reads, "ready paged/SSD capacity alone must not start the cold request")
}

func TestReleaseDefaultReadinessRejectsUnprovenMTP(t *testing.T) {
	for _, mutate := range []func(map[string]any){
		func(p map[string]any) { p["mtp_active"] = false },
		func(p map[string]any) { delete(p, "mtp_active") },
		func(p map[string]any) { p["mtp_enabled"] = false },
		func(p map[string]any) { p["mtp_inactive_reason"] = "inert_kv_unsupported" },
		func(p map[string]any) { p["model"] = "other-model" },
		func(p map[string]any) { p["kv_backend"] = "contiguous" },
		func(p map[string]any) { p["kv_backend_requested"] = "paged" },
		func(p map[string]any) { p["kv_backend_fallback_reason"] = "kernel_preflight" },
		func(p map[string]any) { p["load_error"] = "load refused" },
	} {
		in, expected, slots, posture := releaseDefaultReadinessFixture(t)
		now := time.Now()
		require.NoError(t, validateReleaseDefaultReadiness(slots, in, expected, releaseDefaultDaemonFixture(t, now, posture), now, now))
		mutate(posture)
		require.Error(t, validateReleaseDefaultReadiness(slots, in, expected, releaseDefaultDaemonFixture(t, now, posture), now, now))
	}
	in, expected, slots, posture := releaseDefaultReadinessFixture(t)
	now := time.Now()
	for _, raw := range [][]byte{nil, []byte(`{}`), []byte(`{"schema":1,"pid":123,"written_at":0}`),
		releaseDefaultDaemonFixture(t, now.Add(-time.Second), posture),
		releaseDefaultDaemonFixture(t, now.Add(2*time.Second), posture),
		releaseDefaultDaemonFixture(t, now), releaseDefaultDaemonFixture(t, now, posture, posture)} {
		require.Error(t, validateReleaseDefaultReadiness(slots, in, expected, raw, now, now))
	}
	require.Error(t, validateReleaseDefaultReadiness(slots, in, expected,
		releaseDefaultDaemonFixture(t, now, posture), now.Add(-time.Minute), now.Add(11*time.Second)), "old active snapshots must expire")
}

func TestReleaseDefaultReadinessWaitsForDrainAndKeepsCacheGate(t *testing.T) {
	in, expected, slots, posture := releaseDefaultReadinessFixture(t)
	now := time.Now()
	raw := releaseDefaultDaemonFixture(t, now, posture)
	for _, state := range []string{"reloading", "running", "crashed", "idle_shutdown", ""} {
		slots[0].Capacity.Slots[0].State = state
		require.Error(t, validateReleaseDefaultReadiness(slots, in, expected, raw, now, now))
	}
	slots[0].Capacity.Slots[0].State = "idle"
	slots[0].Capability.Ready = false
	require.Error(t, validateReleaseDefaultReadiness(slots, in, expected, raw, now, now), "MTP activation must not bypass SSD readiness")
}

func TestReleaseDefaultReadinessTimesOutWithLastMTPReason(t *testing.T) {
	in, expected, slots, posture := releaseDefaultReadinessFixture(t)
	posture["mtp_active"] = false
	posture["mtp_inactive_reason"] = "assistant_downloading"
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := waitForReleaseDefaultReadiness(ctx, in, expected, func() bool { return true },
		func(context.Context) ([]byte, error) { return releaseDefaultDaemonFixture(t, time.Now(), posture), nil },
		func() []connectedSlot { return slots }, func(context.Context, string) error { t.Fatal("inactive MTP must not be probed"); return nil })
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.ErrorContains(t, err, "assistant_downloading")
}

func TestReleaseDefaultReadinessStopsWithProviderOrContext(t *testing.T) {
	in, expected, _, _ := releaseDefaultReadinessFixture(t)
	readState := func(context.Context) ([]byte, error) { t.Fatal("terminal wait must not read state"); return nil, nil }
	readSlots := func() []connectedSlot { t.Fatal("terminal wait must not read capacity"); return nil }
	confirm := func(context.Context, string) error { t.Fatal("terminal wait must not probe"); return nil }
	err := waitForReleaseDefaultReadiness(context.Background(), in, expected, func() bool { return false }, readState, readSlots, confirm)
	require.ErrorContains(t, err, "provider exited")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = waitForReleaseDefaultReadiness(ctx, in, expected, func() bool { t.Fatal("cancelled wait must not poll"); return false }, readState, readSlots, confirm)
	require.ErrorIs(t, err, context.Canceled)
}

func TestReleaseDefaultReadinessDoesNotRequireGPTOSSMTP(t *testing.T) {
	in, _, slots, _ := releaseDefaultReadinessFixture(t)
	in.Artifact.ModelID = "gpt-oss-20b"
	slots[0].Model = in.Artifact.ModelID
	slots[0].CacheStatus.ModelID = in.Artifact.ModelID
	slots[0].Capability.ModelID = in.Artifact.ModelID
	slots[0].Capacity.Slots[0].Model = in.Artifact.ModelID
	expected, err := releaseDefaultSelection(in)
	require.NoError(t, err)
	err = waitForReleaseDefaultReadiness(context.Background(), in, expected, func() bool { return true },
		func(context.Context) ([]byte, error) {
			t.Fatal("GPT-OSS must not wait for an MTP upgrade")
			return nil, nil
		},
		func() []connectedSlot { return slots }, func(context.Context, string) error { t.Fatal("GPT-OSS must not probe for MTP admission"); return nil })
	require.NoError(t, err)
}

func TestReleaseDefaultAdmissionQuoteRequiresCorrelationAndPositiveSequence(t *testing.T) {
	pair := func() []testbed.ProviderWireEvent {
		return []testbed.ProviderWireEvent{
			{Connection: 1, Type: "capacity_probe", Direction: "coordinator_to_provider", Fields: map[string]json.RawMessage{"quote_id": []byte(`"probe"`), "model": []byte(`"model"`)}},
			{Connection: 1, Type: "capacity_quote", Direction: "provider_to_coordinator", Fields: map[string]json.RawMessage{"quote_id": []byte(`"probe"`), "capacity_seq": []byte(`5`), "admissible_now": []byte(`true`)}},
		}
	}
	quote, err := releaseDefaultAdmissionQuote(pair(), "probe", "model")
	require.NoError(t, err)
	require.Equal(t, uint64(5), quote.CapacitySeq)
	for _, tc := range []struct {
		name   string
		mutate func([]testbed.ProviderWireEvent)
	}{
		{"other connection", func(e []testbed.ProviderWireEvent) { e[1].Connection = 2 }},
		{"quote before probe", func(e []testbed.ProviderWireEvent) { e[0], e[1] = e[1], e[0] }},
		{"other model", func(e []testbed.ProviderWireEvent) { e[0].Fields["model"] = []byte(`"other"`) }},
		{"missing sequence", func(e []testbed.ProviderWireEvent) { delete(e[1].Fields, "capacity_seq") }},
		{"zero sequence", func(e []testbed.ProviderWireEvent) { e[1].Fields["capacity_seq"] = []byte(`0`) }},
		{"negative", func(e []testbed.ProviderWireEvent) {
			e[1].Fields["admissible_now"] = []byte(`false`)
			e[1].Fields["rejection_reason"] = []byte(`"slot_state"`)
		}},
		{"contradictory reason", func(e []testbed.ProviderWireEvent) { e[1].Fields["rejection_reason"] = []byte(`"slot_state"`) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			events := pair()
			tc.mutate(events)
			_, err := releaseDefaultAdmissionQuote(events, "probe", "model")
			require.Error(t, err)
		})
	}
	for _, mutate := range []func([]testbed.ProviderWireEvent){
		func(e []testbed.ProviderWireEvent) { e[1].Fields["quote_id"] = []byte(`"stale-probe"`) },
		func(e []testbed.ProviderWireEvent) { e[1].Direction = "coordinator_to_provider" },
	} {
		events := pair()
		mutate(events)
		quote, err := releaseDefaultAdmissionQuote(events, "probe", "model")
		require.NoError(t, err)
		require.Nil(t, quote, "unrelated frames cannot confirm this probe")
	}
}

// Real Go WebSockets, the real registry writer and heartbeat ingest, and a
// synthetic provider that only answers control messages. No Swift or model runs.
type releaseDefaultControlFixture struct {
	ctx      context.Context
	registry *registry.Registry
	relay    *testbed.ProviderWireRelay
	provider *registry.Provider
	client   *websocket.Conn
	model    string
}

func newReleaseDefaultControlFixture(t *testing.T) releaseDefaultControlFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	model := "release-default-fixture"
	registered := make(chan *registry.Provider, 1)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		conn, err := websocket.Accept(w, req, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		provider := reg.Register("readiness-provider", conn, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: model}}})
		registered <- provider
		for {
			_, raw, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var heartbeat protocol.HeartbeatMessage
			if json.Unmarshal(raw, &heartbeat) == nil && heartbeat.Type == "heartbeat" {
				reg.Heartbeat(provider.ID, &heartbeat)
			}
		}
	}))
	relay := &testbed.ProviderWireRelay{}
	url := relay.Start(backend.URL)
	client, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(url, "http")+"/ws/provider", nil)
	if err != nil {
		cancel()
		relay.Close()
		backend.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cancel()
		client.CloseNow()
		reg.Disconnect("readiness-provider")
		relay.Close()
		backend.Close()
	})
	var provider *registry.Provider
	select {
	case provider = <-registered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	return releaseDefaultControlFixture{ctx, reg, relay, provider, client, model}
}

func (f releaseDefaultControlFixture) heartbeat(t *testing.T, seq uint64, state string) {
	t.Helper()
	raw, err := json.Marshal(protocol.HeartbeatMessage{Type: "heartbeat", Status: "idle", WarmModels: []string{f.model},
		BackendCapacity: &protocol.BackendCapacity{CapacitySeq: seq, Slots: []protocol.BackendSlotCapacity{{Model: f.model, State: state, MaxConcurrency: 1, ActiveTokenBudgetMax: 4096}}}})
	require.NoError(t, err)
	require.NoError(t, f.client.Write(f.ctx, websocket.MessageText, raw))
	require.Eventually(t, func() bool {
		f.provider.Mu().Lock()
		defer f.provider.Mu().Unlock()
		return f.provider.BackendCapacity != nil && f.provider.BackendCapacity.CapacitySeq == seq
	}, time.Second, time.Millisecond)
}

func (f releaseDefaultControlFixture) probe(t *testing.T) protocol.CapacityProbeMessage {
	t.Helper()
	_, raw, err := f.client.Read(f.ctx)
	require.NoError(t, err)
	var probe protocol.CapacityProbeMessage
	require.NoError(t, json.Unmarshal(raw, &probe))
	require.Equal(t, protocol.TypeCapacityProbe, probe.Type, "readiness must never submit inference")
	require.Equal(t, f.model, probe.Model)
	require.Len(t, probe.QuoteID, 32)
	require.Zero(t, f.provider.PendingCount(), "control probes must not reserve admission")
	return probe
}

func (f releaseDefaultControlFixture) quote(t *testing.T, probe protocol.CapacityProbeMessage, seq uint64, admissible bool) {
	t.Helper()
	quote := protocol.CapacityQuoteMessage{Type: protocol.TypeCapacityQuote, QuoteID: probe.QuoteID, CapacitySeq: seq, AdmissibleNow: admissible}
	if !admissible {
		quote.RejectionReason = protocol.RejectionReasonSlotState
	}
	raw, err := json.Marshal(quote)
	require.NoError(t, err)
	require.NoError(t, f.client.Write(f.ctx, websocket.MessageText, raw))
}

func TestReleaseDefaultAdmissionWaitsForQuotedHeartbeatApplication(t *testing.T) {
	f := newReleaseDefaultControlFixture(t)
	f.heartbeat(t, 3, "idle")
	done := make(chan error, 1)
	go func() { done <- confirmReleaseDefaultAdmission(f.ctx, f.registry, f.relay, f.provider.ID, f.model) }()
	probe := f.probe(t)
	f.quote(t, probe, 5, true)
	// Active local posture and the old idle heartbeat must not win while the
	// positive quote's newer serving snapshot is still in transit.
	require.Never(t, func() bool { return len(done) != 0 }, 80*time.Millisecond, 5*time.Millisecond)
	f.heartbeat(t, 4, "reloading")
	require.Never(t, func() bool { return len(done) != 0 }, 80*time.Millisecond, 5*time.Millisecond)
	f.heartbeat(t, 6, "reloading")
	require.Never(t, func() bool { return len(done) != 0 }, 80*time.Millisecond, 5*time.Millisecond)
	f.heartbeat(t, 7, "idle")
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	require.Zero(t, f.provider.PendingCount())
}

func TestReleaseDefaultAdmissionRejectsDrainAndEndsOnCancellationOrDisconnect(t *testing.T) {
	for _, outcome := range []string{"drain", "cancel", "disconnect"} {
		t.Run(outcome, func(t *testing.T) {
			f := newReleaseDefaultControlFixture(t)
			f.heartbeat(t, 3, "idle")
			ctx, cancel := context.WithCancel(f.ctx)
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- confirmReleaseDefaultAdmission(ctx, f.registry, f.relay, f.provider.ID, f.model) }()
			probe := f.probe(t)
			switch outcome {
			case "drain":
				f.quote(t, probe, 3, false)
			case "cancel":
				cancel()
			case "disconnect":
				f.registry.Disconnect(f.provider.ID)
			}
			select {
			case err := <-done:
				require.Error(t, err)
				if outcome == "drain" {
					require.ErrorContains(t, err, "slot_state")
				} else if outcome == "cancel" {
					require.ErrorIs(t, err, context.Canceled)
				} else {
					require.ErrorContains(t, err, "session changed")
				}
			case <-f.ctx.Done():
				t.Fatal(f.ctx.Err())
			}
		})
	}
}
