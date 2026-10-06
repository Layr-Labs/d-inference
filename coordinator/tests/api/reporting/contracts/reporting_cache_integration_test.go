package reporting_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

type statsInvalidationStore struct {
	store.Store
	calls atomic.Int64
}

func (s *statsInvalidationStore) UsageTotals() (store.UsageTotals, error) {
	s.calls.Add(1)
	return s.Store.UsageTotals()
}

// This cross-domain contract runs through the composed handler: provider
// registration and catalog invalidation must leave reporting's shared entry alone.
func TestProviderRegistrationNoLongerEvictsStats(t *testing.T) {
	t.Setenv("EIGENINFERENCE_TRUST_GEO_HEADERS", "1")
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	st := &statsInvalidationStore{Store: memory.NewMemory(store.Config{})}
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetSkipChallenge(true)
	read := func() []byte {
		t.Helper()
		rr := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
		if rr.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
		}
		return rr.Body.Bytes()
	}
	good := read()
	before := st.calls.Load()
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", &websocket.DialOptions{
		HTTPHeader: http.Header{"Cf-Ipcity": {"Austin"}, "Cf-Ipcountry": {"US"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	registration, err := json.Marshal(&protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware: protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, registration); err != nil {
		t.Fatal(err)
	}
	registered := func() bool {
		p := testkit.FindProviderByModel(reg, "model")
		if p == nil {
			return false
		}
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.Location != nil && p.Location.City == "Austin"
	}
	deadline := time.Now().Add(3 * time.Second)
	for !registered() {
		if time.Now().After(deadline) {
			t.Fatal("provider registration did not attach the location")
		}
		time.Sleep(time.Millisecond)
	}
	if !bytes.Equal(read(), good) || st.calls.Load() != before {
		t.Fatal("provider registration evicted shared stats entry")
	}
	srv.SyncModelCatalog()
	if !bytes.Equal(read(), good) || st.calls.Load() != before {
		t.Fatal("catalog invalidation evicted shared stats entry")
	}
	if !bytes.Equal(read(), good) || st.calls.Load() != before {
		t.Fatal("handler recomputed stats after registration")
	}
}
