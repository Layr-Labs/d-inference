// Package operations owns HTTP liveness, readiness and coordinated drain state.
package operations

import (
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Drain tracks ingress independently of provider-side drain state.
// Its zero value is ready; it must not be copied after first use.
type Drain struct {
	httpInflight        atomic.Int64
	coordinatorDraining atomic.Bool
}

// Handler exposes operational views over the same drain state used by ingress.
type Handler struct {
	*Drain
	store                 LogReportStore
	metrics               func() *observation.Metrics
	access                *access.Owner
	logger                *slog.Logger
	maxBodyBytes          int64
	trustSafetyStatus     func() (bool, string)
	writeTokenRateLimited func(http.ResponseWriter, string, string, time.Duration)
	providerCount         func() int
	buildInfo             func() (string, string, string)
}

type LogReportStore interface {
	StoreLogReport(string, []byte) (int64, error)
	GetLogReport(int64) (*store.LogReport, error)
}

type Dependencies struct {
	Metrics       func() *observation.Metrics
	Drain         *Drain
	Access        *access.Owner
	Store         LogReportStore
	Logger        *slog.Logger
	MaxBodyBytes  int64
	TrustSafety   func() (bool, string)
	Reject        func(http.ResponseWriter, string, string, time.Duration)
	ProviderCount func() int
	BuildInfo     func() (string, string, string)
}

func New(deps Dependencies) *Handler {
	return &Handler{Drain: deps.Drain, access: deps.Access, store: deps.Store,
		metrics: deps.Metrics,
		logger:  deps.Logger, maxBodyBytes: deps.MaxBodyBytes,
		trustSafetyStatus: deps.TrustSafety, writeTokenRateLimited: deps.Reject,
		providerCount: deps.ProviderCount, buildInfo: deps.BuildInfo}
}
