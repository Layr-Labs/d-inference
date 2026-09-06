package e2e

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

type connectedCase struct {
	HostEntry []testbed.HostObservation `json:"host_entry,omitempty"`

	RequiredProviderID string                      `json:"required_provider_id,omitempty"`
	Tenant             int                         `json:"tenant_index"`
	Name               string                      `json:"name"`
	Status             string                      `json:"status"`
	Error              string                      `json:"error,omitempty"`
	Request            json.RawMessage             `json:"request,omitempty"` // authored fixture only, no auth
	RequestDateUTC     string                      `json:"request_date_utc"`
	HTTP               connectedStream             `json:"http"`
	Wire               []testbed.ProviderWireEvent `json:"wire"`
	Before             api.ExactCacheStatus        `json:"before"`
	After              api.ExactCacheStatus        `json:"after"`
	SlotsBefore        []connectedSlot             `json:"slots_before"`
	SlotsAfter         []connectedSlot             `json:"slots_after"`
}
type connectedSlot struct {
	ProviderID string                            `json:"provider_id"`
	Model      string                            `json:"model"`
	Aggregate  string                            `json:"aggregate"`
	Templates  map[string]string                 `json:"template_hashes"`
	Capability *protocol.PrefixCacheV2Capability `json:"cache_capability,omitempty"`
	Capacity   *protocol.BackendCapacity         `json:"capacity,omitempty"`
}
type connectedReport struct {
	HostLifecycles []testbed.ProviderHostLifecycle `json:"host_lifecycles,omitempty"`
	Scope          string                          `json:"scope,omitempty"`
	Hosts          []testbed.ProviderHostBinding   `json:"hosts,omitempty"`

	Schema      int                         `json:"schema"`
	State       string                      `json:"state"`
	Input       connectedCacheInput         `json:"input"`
	Cases       []connectedCase             `json:"cases"`
	Wire        []testbed.ProviderWireEvent `json:"wire"`
	WireDropped int                         `json:"wire_dropped"`
	Routes      []map[string]any            `json:"routing_decisions"`
	Limits      []string                    `json:"limitations"`
}

func saveConnectedReport(t *testing.T, root string, report *connectedReport) {
	t.Helper()
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Errorf("marshal report: %v", err)
		return
	}
	path := filepath.Join(root, "report.json")
	if err = os.WriteFile(path+".tmp", data, 0600); err == nil {
		err = os.Rename(path+".tmp", path)
	}
	if err != nil {
		t.Errorf("save partial report: %v", err)
	}
}
func connectedSlots(s *testbed.Suite, model string) []connectedSlot {
	out := []connectedSlot{}
	for _, p := range liveProviders(s.Coordinator.Registry) {
		p.Mu().Lock()
		slot := connectedSlot{ProviderID: p.ID, Model: model, Templates: map[string]string{}}
		for k, v := range p.TemplateHashes {
			slot.Templates[k] = v
		}
		for _, m := range p.Models {
			if m.ID == model {
				slot.Aggregate = m.WeightHash
			}
		}
		if c, ok := p.PrefixCacheV2Models[model]; ok {
			copy := c
			slot.Capability = &copy
		}
		if p.BackendCapacity != nil {
			raw, _ := json.Marshal(p.BackendCapacity)
			_ = json.Unmarshal(raw, &slot.Capacity)
		}
		p.Mu().Unlock()
		out = append(out, slot)
	}
	return out
}

// Reuse the scheduler's existing debug observation. No request, scope, key or
// prompt body is added to production telemetry for this fixture.
type connectedRouteLog struct {
	mu   sync.Mutex
	rows []map[string]any
}

func (l *connectedRouteLog) Enabled(context.Context, slog.Level) bool { return true }
func (l *connectedRouteLog) Handle(_ context.Context, r slog.Record) error {
	if r.Message != "routing_decision" {
		return nil
	}
	row := map[string]any{"at": time.Now().UTC()}
	r.Attrs(func(a slog.Attr) bool { row[a.Key] = a.Value.Any(); return true })
	l.mu.Lock()
	l.rows = append(l.rows, row)
	l.mu.Unlock()
	return nil
}
func (l *connectedRouteLog) WithAttrs([]slog.Attr) slog.Handler { return l }
func (l *connectedRouteLog) WithGroup(string) slog.Handler      { return l }
func (l *connectedRouteLog) snapshot() []map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	raw, _ := json.Marshal(l.rows)
	var out []map[string]any
	_ = json.Unmarshal(raw, &out)
	return out
}
