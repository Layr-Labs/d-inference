package inference

import (
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestServerConfig contains only composition settings used by lifecycle tests.
// It is translated by the external test package into the real API constructor.
type TestServerConfig struct {
	AdminKey                 string
	ServiceReservations      bool
	FirstContentDeadlineBase time.Duration
	FirstContentSLAAccounts  []string
	MediaFetch               *mediafetch.Config
}

type TestComposition struct {
	Owner                *Owner
	Handler              func() http.Handler
	Close                func()
	BindBilling          func(*billing.Service)
	SyncCatalog          func()
	SetChallengeInterval func(time.Duration)
}

var testFactory func(*registry.Registry, store.Store, TestServerConfig, *slog.Logger) TestComposition
var testCompositions sync.Map

// RegisterTestFactory is visible only in the test build. The external package
// supplies the actual API graph without an inference -> api production cycle.
func RegisterTestFactory(f func(*registry.Registry, store.Store, TestServerConfig, *slog.Logger) TestComposition) {
	testFactory = f
}

func newComposedServer(r *registry.Registry, st store.Store, cfg TestServerConfig, logger *slog.Logger) *Owner {
	if testFactory == nil {
		panic("real API test factory was not registered")
	}
	c := testFactory(r, st, cfg, logger)
	testCompositions.Store(c.Owner, c)
	return c.Owner
}

func testComposition(owner *Owner) TestComposition {
	if c, ok := testCompositions.Load(owner); ok {
		return c.(TestComposition)
	}
	panic("fixture does not have a real API composition")
}

func (s *Owner) Handler() http.Handler { return testComposition(s).Handler() }

func (s *Owner) Close() {
	if c, ok := testCompositions.LoadAndDelete(s); ok {
		c.(TestComposition).Close()
		return
	}
	s.CloseResources()
}
