package provider_test

import (
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
	"nhooyr.io/websocket"
)

// Pause a real store read after registration/attestation, before its telemetry.
type registrationTelemetryStore struct {
	store.Store
	entered chan struct{}
	release chan struct{}
}

func (s *registrationTelemetryStore) GetMDAChainBySerial(ctx context.Context, serial string) (json.RawMessage, error) {
	close(s.entered)
	select {
	case <-s.release:
		return s.Store.GetMDAChainBySerial(ctx, serial)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type registrationTelemetryLog struct {
	slog.Handler
	records chan slog.Record
}

func (h registrationTelemetryLog) Handle(ctx context.Context, record slog.Record) error {
	if record.Message == "telemetry: provider registered" {
		h.records <- record.Clone()
	}
	return h.Handler.Handle(ctx, record)
}

func TestProviderRegistrationTelemetryConcurrentTrustUpdates(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st := &registrationTelemetryStore{
		Store: memory.NewMemory(store.Config{}), entered: make(chan struct{}), release: make(chan struct{}),
	}
	logger := quietLogger()
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	defer srv.Close()
	records := make(chan slog.Record, 1)
	srv.SetEmitter(telemetry.NewEmitter(slog.New(registrationTelemetryLog{Handler: logger.Handler(), records: records}), nil, "test"))

	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	dd, err := datadog.NewClient(datadog.Config{StatsdAddr: udp.LocalAddr().String(), FlushSecs: 60}, logger)
	if err != nil {
		t.Fatal(err)
	}
	defer dd.Close()
	srv.SetDatadog(dd)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	pubKey := testkit.PublicKeyB64()
	msg, err := json.Marshal(protocol.RegisterMessage{
		Type: protocol.TypeRegister, PublicKey: pubKey, Attestation: testkit.CreateAttestationJSONWithSerial(t, "registration-telemetry", pubKey),
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, msg); err != nil {
		t.Fatal(err)
	}
	select {
	case <-st.entered:
	case <-ctx.Done():
		t.Fatal("registration did not reach the store barrier")
	}
	providers := reg.ListProviders()
	if len(providers) != 1 {
		t.Fatalf("registered providers = %d, want 1", len(providers))
	}
	id := providers[0].ID
	updatesCtx, stopUpdates := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		reg.SetTrustLevel(id, registry.TrustHardware)
		close(st.release)
		for {
			select {
			case <-updatesCtx.Done():
				return
			default:
				reg.SetTrustLevel(id, registry.TrustSelfSigned)
				reg.SetTrustLevel(id, registry.TrustHardware)
			}
		}
	}()
	defer func() { stopUpdates(); <-done }()

	var record slog.Record
	select {
	case record = <-records:
	case <-ctx.Done():
		t.Fatal("registration telemetry did not complete during trust updates")
	}
	stopUpdates()
	<-done
	fields := make(map[string]any)
	record.Attrs(func(a slog.Attr) bool { fields[a.Key] = a.Value.Any(); return true })
	level, _ := fields["trust_level"].(string)
	if level != string(registry.TrustHardware) && level != string(registry.TrustSelfSigned) {
		t.Fatalf("unexpected registration trust level: %q", level)
	}
	if fields["provider_id"] != id || fields["hardware_chip"] != "Apple M3 Max" || fields["memory_gb"] != int64(64) || fields["kind"] != protocol.KindLog {
		t.Fatalf("registration telemetry contract changed: %v", fields)
	}
	var registrations int64
	for key, count := range srv.Metrics().Snapshot().Counters {
		if strings.HasPrefix(key, "provider_registrations_total{") {
			registrations += count
			if key != "provider_registrations_total{trust_level="+level+"}" || count != 1 {
				t.Errorf("counter disagrees with registration event: %s=%d, event=%q", key, count, level)
			}
		}
	}
	if registrations != 1 {
		t.Fatalf("registration counter = %d, want 1", registrations)
	}
	if err := udp.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 65536)
	for {
		n, _, err := udp.ReadFrom(buf)
		if err != nil {
			t.Fatalf("waiting for registration DogStatsD counter: %v", err)
		}
		for _, line := range strings.Split(string(buf[:n]), "\n") {
			if strings.Contains(line, "providers.registrations:") {
				if !strings.Contains(line, "providers.registrations:1|c|") || !strings.Contains(line, "trust_level:"+level) {
					t.Fatalf("DogStatsD counter disagrees with registration event: %q, event=%q", line, level)
				}
				return
			}
		}
	}
}
