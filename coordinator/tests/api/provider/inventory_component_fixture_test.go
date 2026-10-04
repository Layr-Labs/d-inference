package provider_test

import (
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/heartbeat"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/inventory"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// These component tests control call contexts independently of a live Owner
// session while retaining the real provider writer and socket.
type inventoryComponentFixture struct {
	registry   *registry.Registry
	catalog    *catalog.Owner
	logger     *slog.Logger
	controller *inventory.Controller
	ingestor   *heartbeat.Ingestor
}

func connectedInventoryComponent(t *testing.T) (*inventoryComponentFixture, *registry.Provider, *websocket.Conn) {
	t.Helper()
	s, p, peer := connectedTestProvider(t)
	return &inventoryComponentFixture{
		registry: s.registry, catalog: s.catalog, logger: s.logger,
		controller: inventory.New(s.registry, s.catalog.ProviderSupportsDesiredModels, s.logger),
		ingestor:   heartbeat.New(s.registry, s.observation),
	}, p, peer
}
