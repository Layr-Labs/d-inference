package registry_test

import (
	"encoding/json"
	"log/slog"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

var warmFixtures sync.Map

type warmPoolFixture struct {
	runtime    *warmplan.Controller[production.ModelLoadAction]
	deps       warmplan.Dependencies[production.ModelLoadAction]
	sender     func(string, string) error
	writers    []*providerwrite.Writer
	loads      *production.ModelLoadPlanner
	histories  sync.Map
	loadStates sync.Map
}

func newWarmRegistry(t *testing.T, logger ...*slog.Logger) *production.Registry {
	return newWarmRegistryWithDeps(t, nil, logger...)
}

func newWarmRegistryWithDeps(t *testing.T, configure func(*production.Dependencies), logger ...*slog.Logger) *production.Registry {
	t.Helper()
	f := &warmPoolFixture{}
	log := testLogger()
	if len(logger) != 0 {
		log = logger[0]
	}
	deps := production.Dependencies{
		Connections: f,
		WarmLifecycle: func(session string) warmplan.LoadLifecycle {
			state := &recordingWarmLoads{LoadState: new(warmplan.LoadState)}
			f.loadStates.Store(session, state)
			return state
		},
		WarmHistory: func(session string) *warmplan.WorkHistory {
			history := new(warmplan.WorkHistory)
			f.histories.Store(session, history)
			return history
		},
		ModelLoadPlanning: func(planner *production.ModelLoadPlanner) production.ModelLoadPlanning {
			f.loads = planner
			return planner
		},
		WarmPlanning: func(deps warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			f.deps = deps
			f.runtime = warmplan.NewController(deps)
			return f.runtime
		},
	}
	if configure != nil {
		configure(&deps)
	}
	r := production.NewWithDependencies(log, deps)
	warmFixtures.Store(r, f)
	t.Cleanup(func() {
		for _, writer := range f.writers {
			writer.Close()
			<-writer.Done()
		}
		warmFixtures.Delete(r)
	})
	return r
}

func warmFixtureFor(r *production.Registry) *warmPoolFixture {
	f, ok := warmFixtures.Load(r)
	if !ok {
		panic("registry was not created with retained warm components")
	}
	return f.(*warmPoolFixture)
}

func (f *warmPoolFixture) Open(id string, _ *websocket.Conn) *providerwrite.Writer {
	w := providerwrite.New(&warmPoolTransport{fixture: f, id: id, stop: make(chan struct{})}, nil)
	f.writers = append(f.writers, w)
	go w.Run()
	return w
}

type warmPoolTransport struct {
	fixture *warmPoolFixture
	id      string
	stop    chan struct{}
	once    sync.Once
}

func (t *warmPoolTransport) Write(data []byte) error {
	select {
	case <-t.stop:
		return providerwrite.ErrStopped
	default:
	}
	var msg protocol.LoadModelMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return err
	}
	if msg.Type == protocol.TypeLoadModel && t.fixture.sender != nil {
		return t.fixture.sender(t.id, msg.ModelID)
	}
	return nil
}

func (t *warmPoolTransport) Close() { t.once.Do(func() { close(t.stop) }) }

func (t *warmPoolTransport) Watch(stop, writerStop <-chan struct{}) {
	select {
	case <-stop:
	case <-writerStop:
	}
}

func (f *warmPoolFixture) history(session string) *warmplan.WorkHistory {
	history, ok := f.histories.Load(session)
	if !ok {
		panic("session has no retained work history")
	}
	return history.(*warmplan.WorkHistory)
}

func (f *warmPoolFixture) lifecycle(session string) *recordingWarmLoads {
	state, ok := f.loadStates.Load(session)
	if !ok {
		panic("session has no retained load lifecycle")
	}
	return state.(*recordingWarmLoads)
}
