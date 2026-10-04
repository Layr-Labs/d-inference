package profile

import (
	"hash/fnv"
	"log/slog"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	routes "github.com/eigeninference/d-inference/coordinator/internal/observation/routes"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	EnvProfiler             = env.EnvPrefix + "_PROFILER"
	EnvProfileSampleRate    = env.EnvPrefix + "_PROFILE_SAMPLE_RATE"
	defaultProfileSample    = 0.1
	profileSlowFirstContent = 5 * time.Second
	profileSlowTotal        = 30 * time.Second
)

type Config struct {
	Enabled    bool
	SampleRate float64
}

type RecordStore interface {
	RecordRequestProfiles([]*store.RequestProfileRecord) error
}

type Dependencies struct {
	Store  RecordStore
	Logger *slog.Logger
	Incr   func(string, []string)
	Count  func(string, int64, []string)
}

// Profiler owns prompt-free record construction, sampling and its bounded sink.
type Profiler struct {
	enabled    bool
	sampleRate float64
	logger     *slog.Logger
	sink       *profileSink
	store      RecordStore
	incr       func(string, []string)
	count      func(string, int64, []string)
}

func NewFromEnv(deps Dependencies) *Profiler {
	return New(Config{
		Enabled:    !strings.EqualFold(strings.TrimSpace(env.EnvOr(EnvProfiler, "on")), "off"),
		SampleRate: env.EnvFloat(EnvProfileSampleRate, defaultProfileSample),
	}, deps)
}

func New(config Config, deps Dependencies) *Profiler {
	p := &Profiler{
		enabled: config.Enabled, sampleRate: config.SampleRate,
		logger: deps.Logger, store: deps.Store, incr: deps.Incr, count: deps.Count,
	}
	if p.sampleRate < 0 {
		p.sampleRate = 0
	}
	if p.sampleRate > 1 {
		p.sampleRate = 1
	}
	if p.enabled && p.store != nil {
		p.sink = newProfileSink(p, routes.DefaultCapacity)
	}
	return p
}

func (p *Profiler) Enabled() bool { return p != nil && p.enabled }
func (p *Profiler) HasSink() bool { return p != nil && p.sink != nil }
func (p *Profiler) Depth() int {
	if p == nil {
		return 0
	}
	return p.sink.depth()
}
func (p *Profiler) DroppedTotal() int64 {
	if p == nil {
		return 0
	}
	return p.sink.droppedTotal()
}
func (p *Profiler) Submit(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	if !p.Enabled() {
		return false
	}
	return p.sink.submit(rp, ap)
}
func (p *Profiler) ddIncr(name string, tags []string) {
	if p != nil && p.incr != nil {
		p.incr(name, tags)
	}
}
func (p *Profiler) ddCount(name string, n int64, tags []string) {
	if p != nil && p.count != nil {
		p.count(name, n, tags)
	}
}

func (p *Profiler) Close() {
	if p == nil || p.sink == nil {
		return
	}
	p.sink.Close()
}

// Sampled decides, per logical request, whether a success record is kept.
// Deterministic on the coordinator-minted id so every attempt of a request
// lands together; a missing id (no middleware) is always kept.
func (p *Profiler) Sampled(coordID string) bool {
	if p == nil {
		return false
	}
	if p.sampleRate >= 1 || coordID == "" {
		return true
	}
	if p.sampleRate <= 0 {
		return false
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(coordID))
	// Map the hash to [0,1) and compare; FNV spreads short ids well enough for
	// a fixed-rate sample and costs no allocation.
	frac := float64(h.Sum32()) / float64(1<<32)
	return frac < p.sampleRate
}
