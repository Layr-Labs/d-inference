package provider_test

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	providerapi "github.com/eigeninference/d-inference/coordinator/api/provider"
	"github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/heartbeat"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/inventory"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/session"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type Dependencies = providerapi.Dependencies

// Keep the real dependencies, not owner accessors or copies of owner state.
type Owner struct {
	*providerapi.Owner
	registry    *registry.Registry
	store       store.Store
	trust       *trust.Owner
	catalog     *catalog.Owner
	observation *observation.Owner
	logger      *slog.Logger
	heartbeat   *heartbeat.Ingestor
	inventory   *inventory.Controller
	sessions    *session.Gate
}

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
func newProviderFixture(t testing.TB, d Dependencies) *Owner {
	t.Helper()
	d.Registry.SetStore(d.Store)
	cache := readcache.New()
	auth := access.New(d.Store, d.Logger, 64<<10, access.Hooks{})
	d.Observation = observation.New(observation.Dependencies{Store: d.Store, Registry: d.Registry, Logger: d.Logger})
	t.Cleanup(d.Observation.Close)
	d.Releases = releases.New(d.Registry, d.Store, auth, cache, d.Logger, releases.Hooks{})
	d.Catalog = catalog.New(d.Registry, d.Store, auth, cache, d.Logger, catalog.Hooks{})
	var owner *Owner
	d.Trust = trust.New(trust.Dependencies{Registry: d.Registry, Store: d.Store, Access: auth, Releases: d.Releases, Observation: d.Observation, ReadCache: cache, Logger: d.Logger,
		Hooks: trust.Hooks{RestoreProviderState: func(ctx context.Context, p *registry.Provider, serial, key string, account ...string) error {
			return owner.RestorePersistedProviderState(ctx, p, serial, key, account...)
		}}}, trust.Config{})
	d.Sessions = &session.Gate{}
	owner = &Owner{Owner: providerapi.New(d), registry: d.Registry, store: d.Store,
		trust: d.Trust, catalog: d.Catalog, observation: d.Observation, logger: d.Logger,
		sessions: d.Sessions, heartbeat: heartbeat.New(d.Registry, d.Observation),
		inventory: inventory.New(d.Registry, d.Catalog.ProviderSupportsDesiredModels, d.Logger)}
	d.Trust.Start()
	t.Cleanup(d.Trust.Close)
	return owner
}
func providerTestOwner(t testing.TB) (*Owner, *memory.MemoryStore) {
	t.Helper()
	logger := quietLogger()
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	return newProviderFixture(t, Dependencies{Registry: registry.New(logger), Store: st, Logger: logger}), st
}
func providerTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func waitFor(t *testing.T, d time.Duration, label string, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for !fn() {
		if time.Now().After(deadline) {
			t.Fatal(label)
		}
		time.Sleep(time.Millisecond)
	}
}

type udpCollector struct {
	conn    *net.UDPConn
	packets chan string
	done    chan struct{}
}

func newUDPCollector(t *testing.T) *udpCollector {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	c := &udpCollector{
		conn:    conn,
		packets: make(chan string, 256),
		done:    make(chan struct{}),
	}
	go func() {
		defer close(c.done)
		buf := make([]byte, 8192)
		for {
			n, _, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, line := range strings.Split(string(buf[:n]), "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					c.packets <- line
				}
			}
		}
	}()
	return c
}

func (c *udpCollector) Addr() string {
	return c.conn.LocalAddr().String()
}

func (c *udpCollector) Close() {
	c.conn.Close()
	<-c.done
}

func (c *udpCollector) drain() []string {
	time.Sleep(200 * time.Millisecond)
	var out []string
	for {
		select {
		case p := <-c.packets:
			out = append(out, p)
		default:
			return out
		}
	}
}

func hasMetric(packets []string, substr string) bool {
	for _, p := range packets {
		if strings.Contains(p, substr) {
			return true
		}
	}
	return false
}

func findMetrics(packets []string, substr string) []string {
	var out []string
	for _, p := range packets {
		if strings.Contains(p, substr) {
			out = append(out, p)
		}
	}
	return out
}

func newTestDD(t *testing.T, collector *udpCollector) *datadog.Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// Use datadog.NewClient with a config pointing at our collector so all
	// internal fields (logTicker, logDone, etc.) are properly initialized.
	cfg := datadog.Config{
		StatsdAddr: collector.Addr(),
		FlushSecs:  60,
	}
	client, err := datadog.NewClient(cfg, logger)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func makeRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			MemoryGB:           64,
			MemoryBandwidthGBs: 400,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			SIPEnabled:           true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	}
	p := reg.Register(id, nil, msg)
	// This helper constructs an already registered, routable fixture. Recovery
	// failure cases use their own pending-registration fixtures.
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.DecodeTPS = 90.0
	p.PrefillTPS = 500.0
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     64,
		GPUMemoryActiveGB: 8,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.Mu().Unlock()
	return p
}

func metricKey(name string, labels []observation.MetricLabel) string {
	if len(labels) == 0 {
		return name
	}
	labels = append([]observation.MetricLabel(nil), labels...)
	sort.SliceStable(labels, func(i, j int) bool { return labels[i].Name < labels[j].Name })
	parts := make([]string, len(labels))
	for i, l := range labels {
		parts[i] = l.Name + "=" + l.Value
	}
	return name + "{" + strings.Join(parts, ",") + "}"
}

const testTransportModel = "write-accounting-model"

func connectedTestProvider(t *testing.T) (*Owner, *registry.Provider, *websocket.Conn) {
	t.Helper()
	srv, _ := providerTestOwner(t)

	accepted := make(chan *websocket.Conn, 1)
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		accepted <- conn
	}))
	t.Cleanup(httpServer.Close)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	peer, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.CloseNow() })
	conn := <-accepted
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: testTransportModel}})
	p := srv.registry.Register("write-accounting-provider", conn, &protocol.RegisterMessage{
		Backend: registry.BackendMLXSwift, PublicKey: base64.StdEncoding.EncodeToString(keys.PublicKey[:]), EncryptedResponseChunks: true,
		Hardware:            protocol.Hardware{MemoryGB: 64, MemoryAvailableGB: 60},
		Models:              []protocol.ModelInfo{{ID: testTransportModel, ModelType: "chat", SizeBytes: 1}},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()
	p.CompleteProviderStateRestore()
	t.Cleanup(func() { srv.registry.Disconnect(p.ID) })
	return srv, p, peer
}
