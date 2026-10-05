package promptcontract_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// clientDependencies is injected as a sidecar client's PlanAdmissions and
// Transports. It keeps the actual planning admission and the transport of each
// pool the client built, and gives the client exactly those components.
type clientDependencies struct {
	t         *testing.T
	admission *sidecar.PlanAdmission
	pools     map[sidecar.Pool]*http.Transport
	// supervised is the client configuration a supervisor derived from its own
	// effective configuration, observed where the client is built.
	supervised sidecar.ClientConfig
}

func newClientDependencies(t *testing.T) *clientDependencies {
	return &clientDependencies{t: t, pools: make(map[sidecar.Pool]*http.Transport)}
}

// clients is injected as a supervisor's Clients. It builds the supervisor's
// client from the configuration the supervisor derived, with these dependencies.
func (d *clientDependencies) clients(config sidecar.ClientConfig) *sidecar.Client {
	d.supervised = config
	config.PlanAdmissions, config.Transports = d.planAdmissions, d.transports
	return sidecar.NewClient(config)
}

func (d *clientDependencies) planAdmissions(workers int) *sidecar.PlanAdmission {
	d.admission = sidecar.NewPlanAdmission(workers)
	return d.admission
}

func (d *clientDependencies) transports(pool sidecar.Pool, transport *http.Transport) http.RoundTripper {
	d.pools[pool] = transport
	return transport
}

func (d *clientDependencies) planAdmission() *sidecar.PlanAdmission {
	d.t.Helper()
	if d.admission == nil {
		d.t.Fatal("client did not construct its planning admission")
	}
	return d.admission
}

func (d *clientDependencies) pool(pool sidecar.Pool) *http.Transport {
	d.t.Helper()
	transport := d.pools[pool]
	if transport == nil {
		d.t.Fatalf("client did not build its %s pool", pool)
	}
	return transport
}

// httpClient sends requests over the pool's own transport and connections.
func (d *clientDependencies) httpClient(pool sidecar.Pool) *http.Client {
	d.t.Helper()
	return &http.Client{Transport: d.pool(pool)}
}
