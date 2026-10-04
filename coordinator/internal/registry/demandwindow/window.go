// Package demandwindow retains bounded, arrival-clock workload intervals.
package demandwindow

import (
	"sort"
	"sync"
	"time"
)

// Interval and Model are detached aggregation inputs. Count records arrivals,
// independent of the workload value's observed completion or service totals.
type Interval[B any] struct {
	At    time.Time
	Count int
	Value B
}

type Model[B any] struct {
	First, Last time.Time
	Intervals   []Interval[B]
}

type Window[B any] struct {
	mu        sync.Mutex
	models    map[string]*Model[B]
	maxModels int
	width     time.Duration
	merge     func(B, B) B
}

func New[B any](maxModels int, width time.Duration, merge func(B, B) B) *Window[B] {
	return &Window[B]{maxModels: maxModels, width: width, merge: merge}
}

// Record accepts only arrival timestamps inside the current observation window.
// Expiry uses accepted arrivals, so a late terminal cannot renew old workload.
func (w *Window[B]) Record(model string, arrival, now time.Time, horizon time.Duration, value B) bool {
	if model == "" || w.width <= 0 || horizon <= 0 || now.IsZero() || arrival.After(now) || arrival.Before(now.Add(-horizon)) {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.models == nil {
		w.models = make(map[string]*Model[B])
	}
	m := w.models[model]
	if m != nil && m.Last.Before(now.Add(-2*horizon)) {
		delete(w.models, model)
		m = nil
	}
	if m == nil {
		w.pruneModels(now, horizon)
		if len(w.models) >= w.maxModels {
			return false
		}
		m = &Model[B]{First: arrival, Last: arrival}
		w.models[model] = m
	}
	if arrival.Before(m.First) {
		m.First = arrival
	}
	if arrival.After(m.Last) {
		m.Last = arrival
	}
	w.pruneIntervals(m, now.Add(-horizon))
	at := arrival.Truncate(w.width)
	i := sort.Search(len(m.Intervals), func(i int) bool { return !m.Intervals[i].At.Before(at) })
	if i == len(m.Intervals) || !m.Intervals[i].At.Equal(at) {
		m.Intervals = append(m.Intervals, Interval[B]{})
		copy(m.Intervals[i+1:], m.Intervals[i:])
		m.Intervals[i] = Interval[B]{At: at}
	}
	b := &m.Intervals[i]
	b.Count++
	b.Value = w.merge(b.Value, value)
	return true
}

func (w *Window[B]) pruneModels(now time.Time, horizon time.Duration) {
	for id, m := range w.models {
		if m.Last.Before(now.Add(-2 * horizon)) {
			delete(w.models, id)
		}
	}
}

// Keep the interval intersecting the cutoff. At an unaligned tick this retains
// less than one width of old work, never discarding a valid part of the interval.
func (w *Window[B]) pruneIntervals(m *Model[B], cutoff time.Time) {
	at := cutoff.Truncate(w.width)
	i := sort.Search(len(m.Intervals), func(i int) bool { return !m.Intervals[i].At.Before(at) })
	if i > 0 {
		copy(m.Intervals, m.Intervals[i:])
		clear(m.Intervals[len(m.Intervals)-i:])
		m.Intervals = m.Intervals[:len(m.Intervals)-i]
	}
}

// Snapshot detaches interval storage while retaining the exact arrival ordering
// and observation clocks needed by demand aggregation.
func (w *Window[B]) Snapshot(now time.Time, horizon time.Duration) map[string]Model[B] {
	out := make(map[string]Model[B])
	if horizon <= 0 || now.IsZero() {
		return out
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.pruneModels(now, horizon)
	for id, m := range w.models {
		w.pruneIntervals(m, now.Add(-horizon))
		out[id] = Model[B]{First: m.First, Last: m.Last, Intervals: append([]Interval[B](nil), m.Intervals...)}
	}
	return out
}
