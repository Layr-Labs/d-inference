package warmplan

import (
	"log/slog"
	"sync"
	"time"
)

type Dependencies[A any] struct {
	Config       Config
	State        *State
	Wakeups      <-chan struct{}
	Fleet        func(time.Time) map[string]Fleet
	PendingLoads func(time.Time) int
	Reserve      func([]A, time.Time) []A
	Send         func([]A)
	NewAction    func(string, string) A
	Dedicated    func(string) bool
	Logger       *slog.Logger
}

type Controller[A any] struct {
	deps        Dependencies[A]
	config      Config
	state       *State
	queueMu     syncQueuePressure
	tickMu      sync.Mutex
	lastMu      sync.RWMutex
	lastSnaps   []Snapshot[A]
	lastSnapsAt time.Time
}

func NewController[A any](deps Dependencies[A]) *Controller[A] {
	if deps.State == nil {
		deps.State = NewState()
	}
	return &Controller[A]{deps: deps, config: deps.Config, state: deps.State, queueMu: syncQueuePressure{models: make(map[string]QueuePressure)}}
}

func (c *Controller[A]) Configure(cfg Config) { c.config = cfg }
