package registry_test

// Ported from the research branch's in-package tests through the public
// registry API and its injected command transport:
//
//   - TestClusterMemberNeverSoloRoutesEvenWithAdvertisedLoadedOrColdModels
//   - TestVerifiedPairExcludesRealRoutingAndLoadReaders
//   - TestVerifiedPairModelLoadCommitRechecksHold
//   - TestVerifiedPairSeesModelCommandAlreadyBeingWritten
//
// A control-only member connection, and a device held by a verified pair, must
// never be routed solo work or told to start model work (load_model,
// prefetch_model, a nonempty desired_models), and a pair must not be reserved
// across a model command that is already being written.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// pairCommandFixture is the pair environment with the model-command wire, the
// load planner and the warm-pool fleet view observable from outside.
type pairCommandFixture struct {
	r             *production.Registry
	loadPlanner   *production.ModelLoadPlanner
	fleetSnapshot func(time.Time) map[string]warmplan.Fleet

	mu     sync.Mutex
	frames map[string][]string
	// beforeWrite, when set, runs on the writing goroutine for every model
	// command before it is recorded as written.
	beforeWrite func(frameType string)
}

func newPairCommandFixture(t *testing.T) *pairCommandFixture {
	t.Helper()
	f := &pairCommandFixture{frames: make(map[string][]string)}
	f.r = pairEnvironmentWith(t, production.Dependencies{
		ModelCommands: func(session string, _ production.ModelCommandTransport) production.ModelCommandTransport {
			return modelCommandWriteFunc(func(_ context.Context, data []byte) error {
				var envelope struct {
					Type string `json:"type"`
				}
				if err := json.Unmarshal(data, &envelope); err != nil {
					return err
				}
				f.mu.Lock()
				hook := f.beforeWrite
				f.mu.Unlock()
				if hook != nil {
					hook(envelope.Type)
				}
				f.mu.Lock()
				f.frames[session] = append(f.frames[session], string(data))
				f.mu.Unlock()
				return nil
			})
		},
		ModelLoadPlanning: func(planner *production.ModelLoadPlanner) production.ModelLoadPlanning {
			f.loadPlanner = planner
			return planner
		},
		WarmPlanning: func(deps warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			f.fleetSnapshot = deps.Fleet
			return warmplan.NewController(deps)
		},
	})
	f.r.ConfigureWarmPool(warmplan.Config{})
	return f
}

func (f *pairCommandFixture) written(session string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.frames[session]...)
}

func (f *pairCommandFixture) gate(t *testing.T, id string) string {
	t.Helper()
	for _, row := range f.r.FleetSample(time.Now()) {
		if row.ProviderID == id {
			return row.EligibilityReason
		}
	}
	t.Fatalf("no fleet sample row for %s", id)
	return ""
}

// requireNoSoloWork asserts every ordinary routing, warming and load reader
// excludes the two connections for the reason given.
func (f *pairCommandFixture) requireNoSoloWork(t *testing.T, members [2]*production.Provider, gate string, cold warmplan.ColdReason) {
	t.Helper()
	if findRoutableProvider(f.r, nativePairFixtureModel) != nil {
		t.Fatalf("solo route reached a %s connection", gate)
	}
	if count, _, _ := f.r.QuickCapacityCheck(nativePairFixtureModel, 1, 1, production.RequestTraits{}); count != 0 {
		t.Fatalf("%s connection counted as solo capacity", gate)
	}
	for _, p := range members {
		if got := f.gate(t, p.ID); got != gate {
			t.Fatalf("%s meets routing gate %q, want %q", p.ID, got, gate)
		}
	}
	fleet := f.fleetSnapshot(time.Now())[nativePairFixtureModel]
	if fleet.Warm != 0 || len(fleet.EligibleCold) != 0 || fleet.ColdDisq[cold] != len(members) {
		t.Fatalf("warm-pool view admitted a %s connection: warm=%d cold=%d disqualified=%v",
			gate, fleet.Warm, len(fleet.EligibleCold), fleet.ColdDisq)
	}
	planned := []production.ModelLoadAction{{ProviderID: members[1].ID, ModelID: nativePairFixtureModel}}
	if reserved := f.loadPlanner.Reserve(planned, time.Now()); len(reserved) != 0 || f.r.HasPendingModelLoad(members[1].ID, nativePairFixtureModel) {
		t.Fatalf("load plan committed on a %s connection", gate)
	}
}

// requireNoModelWork asserts no command that starts model work crosses to the
// connection, while the empty desired_models revoke still does.
func (f *pairCommandFixture) requireNoModelWork(t *testing.T, p *production.Provider) {
	t.Helper()
	for name, send := range map[string]func() error{
		"load_model":     func() error { return f.r.SendLoadModel(p.ID, nativePairFixtureModel) },
		"prefetch_model": func() error { return f.r.SendPrefetchModel(p.ID, nativePairFixtureModel, 1) },
		"desired_models": func() error {
			return f.r.SendDesiredModels(p.ID, []protocol.DesiredModelEntry{{DesiredBuild: nativePairFixtureModel}})
		},
	} {
		if err := send(); !errors.Is(err, production.ErrVerifiedPairBusy) {
			t.Fatalf("%s crossed to %s: %v", name, p.ID, err)
		}
	}
	if frames := f.written(p.ID); len(frames) != 0 {
		t.Fatalf("model work reached the wire for %s: %v", p.ID, frames)
	}
	if err := f.r.SendDesiredModels(p.ID, nil); err != nil {
		t.Fatalf("empty desired_models revoke refused for %s: %v", p.ID, err)
	}
	if frames := f.written(p.ID); len(frames) != 1 || frames[0] != `{"type":"desired_models","models":[]}` {
		t.Fatalf("empty desired_models revoke not delivered to %s: %v", p.ID, frames)
	}
}

// soloPairDevice registers a fully trusted ordinary solo connection from the
// fixture device with that serial, holding the fixture model idle.
func soloPairDevice(t *testing.T, r *production.Registry, id, serial string) *production.Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: nativePairFixtureModel, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = 90
	processKey := sha256.Sum256([]byte("fixture-process-" + id))
	msg.PublicKey = base64.StdEncoding.EncodeToString(processKey[:])
	solo := r.Register(id, nil, msg)
	trustPairDevice(t, solo, serial, pairDeviceSEKey(serial), &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: nativePairFixtureModel, State: "running"}},
	})
	solo.Mu().Lock()
	solo.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	solo.Mu().Unlock()
	return solo
}

func TestClusterMemberNeverSoloRoutesOrReceivesModelWork(t *testing.T) {
	f := newPairCommandFixture(t)
	members := [2]*production.Provider{
		pairMember(t, f.r, nil, "pair-a", "serial-a", fmt.Sprintf("%064x", 1)),
		pairMember(t, f.r, nil, "pair-b", "serial-b", fmt.Sprintf("%064x", 2)),
	}
	for _, loaded := range []bool{true, false} {
		for _, p := range members {
			p.Mu().Lock()
			p.AccountID = "member-owner"
			p.BackendCapacity.Slots, p.WarmModels, p.CurrentModel = nil, nil, ""
			if loaded {
				p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: nativePairFixtureModel, State: "running"}}
				p.WarmModels, p.CurrentModel = []string{nativePairFixtureModel}, nativePairFixtureModel
			}
			p.Mu().Unlock()
		}
		f.requireNoSoloWork(t, members, "member_only", warmplan.WarmColdMemberOnly)
		// The owner self-route relaxes the trust floor, never the role.
		if _, serves := f.r.OwnedProviderSummary("member-owner", nativePairFixtureModel, production.RequestTraits{}, false); serves != 0 {
			t.Fatal("member entered its owner's self-route")
		}
	}
	f.requireNoModelWork(t, members[0])

	// The pair selector is the one path that admits a member, and it keeps
	// every strict trust requirement.
	h, m, err := f.r.ReserveVerifiedPair(members, pairRequest())
	if err != nil {
		t.Fatalf("member strict pair selection failed: %v", err)
	}
	for _, p := range members {
		if err = f.r.AcknowledgeVerifiedPairPrepared(h, p, m.TranscriptSHA256); err != nil {
			t.Fatalf("prepare: %v", err)
		}
	}
	if _, err = f.r.CommitVerifiedPairOwners(h); err != nil {
		t.Fatalf("commit: %v", err)
	}
	if _, err = f.r.ValidateVerifiedPair(h); err != nil {
		t.Fatalf("active member pair failed validation: %v", err)
	}
	members[0].SetAttested(false, production.TrustNone)
	if _, err = f.r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("member role upgraded trust")
	}
}

func TestVerifiedPairHoldExcludesSoloRoutingAndModelWork(t *testing.T) {
	f := newPairCommandFixture(t)
	members := [2]*production.Provider{
		soloPairDevice(t, f.r, "pair-a", "serial-a"),
		soloPairDevice(t, f.r, "pair-b", "serial-b"),
	}
	if findRoutableProvider(f.r, nativePairFixtureModel) == nil {
		t.Fatal("ordinary solo baseline unavailable")
	}
	h, m, err := f.r.ReserveVerifiedPair(members, pairRequest())
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if m.Members[0].ProcessPublicKey != members[0].PublicKey || m.Members[1].DeviceSerial != "serial-b" ||
		m.Suite != production.VerifiedPairSuite {
		t.Fatal("membership lost live identity binding")
	}
	// requireNoSoloWork also replays a load plan made before the hold.
	f.requireNoSoloWork(t, members, "pair_reserved", warmplan.WarmColdPairReserved)
	f.requireNoModelWork(t, members[0])

	if err = f.r.CancelVerifiedPair(h); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.Done():
	default:
		t.Fatal("pair invalidation was not published")
	}
	if findRoutableProvider(f.r, nativePairFixtureModel) == nil {
		t.Fatal("pending cancel did not restore unchanged solo routing")
	}
	if err = f.r.SendLoadModel(members[0].ID, nativePairFixtureModel); err != nil {
		t.Fatalf("released device refused model work: %v", err)
	}
}

func TestVerifiedPairSeesModelCommandAlreadyBeingWritten(t *testing.T) {
	commands := map[string]func(*production.Registry, string) error{
		protocol.TypeLoadModel: func(r *production.Registry, id string) error {
			return r.SendLoadModel(id, nativePairFixtureModel)
		},
		protocol.TypePrefetchModel: func(r *production.Registry, id string) error {
			return r.SendPrefetchModel(id, nativePairFixtureModel, 1)
		},
		protocol.TypeDesiredModels: func(r *production.Registry, id string) error {
			return r.SendDesiredModels(id, []protocol.DesiredModelEntry{{DesiredBuild: nativePairFixtureModel}})
		},
	}
	for kind, send := range commands {
		t.Run(kind, func(t *testing.T) {
			f := newPairCommandFixture(t)
			members := [2]*production.Provider{
				soloPairDevice(t, f.r, "pair-a", "serial-a"),
				soloPairDevice(t, f.r, "pair-b", "serial-b"),
			}
			entered, finish, result := make(chan struct{}), make(chan struct{}), make(chan error, 1)
			f.mu.Lock()
			f.beforeWrite = func(frameType string) {
				if frameType == kind {
					close(entered)
					<-finish
				}
			}
			f.mu.Unlock()
			go func() { result <- send(f.r, members[0].ID) }()
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				t.Fatal("model command did not reach the wire")
			}
			_, _, err := f.r.ReserveVerifiedPair(members, pairRequest())
			close(finish)
			if writeErr := <-result; writeErr != nil {
				t.Fatal(writeErr)
			}
			if !errors.Is(err, production.ErrVerifiedPairBusy) {
				t.Fatalf("pair crossed a %s write in flight: %v", kind, err)
			}
			if _, _, err = f.r.ReserveVerifiedPair(members, pairRequest()); err != nil {
				t.Fatalf("pair refused after the %s write finished: %v", kind, err)
			}
		})
	}
}

// The coordinator computes no model work for a member in the first place, so
// catalog publication never has an undeliverable desired_models for one.
func TestClusterMemberIsOfferedNoDesiredModels(t *testing.T) {
	f := newPairCommandFixture(t)
	f.r.SetModelCatalog([]production.CatalogEntry{{ID: nativePairFixtureModel}, {ID: "next-build"}})
	f.r.SetModelAliases(map[string]production.AliasTarget{"public-alias": {Desired: "next-build", Previous: nativePairFixtureModel}})
	solo := soloPairDevice(t, f.r, "solo", "serial-solo")
	member := pairMember(t, f.r, nil, "member", "serial-member", fmt.Sprintf("%064x", 1))

	if entries := f.r.DesiredModelsForProvider(solo.ID); len(entries) != 1 || entries[0].DesiredBuild != "next-build" {
		t.Fatalf("solo control lost its alias convergence entry: %+v", entries)
	}
	entries := f.r.DesiredModelsForProvider(member.ID)
	if len(entries) != 0 {
		t.Fatalf("member offered model work: %+v", entries)
	}
	if err := f.r.SendDesiredModels(member.ID, entries); err != nil {
		t.Fatalf("member's computed desired_models was undeliverable: %v", err)
	}
	if err := f.r.RefreshDesiredModels(member); err != nil {
		t.Fatalf("member's refreshed desired_models was undeliverable: %v", err)
	}
	for _, frame := range f.written(member.ID) {
		if frame != `{"type":"desired_models","models":[]}` {
			t.Fatalf("member received model work: %s", frame)
		}
	}
}
