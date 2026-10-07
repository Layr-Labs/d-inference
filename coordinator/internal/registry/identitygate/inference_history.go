package identitygate

import (
	"time"
)

// Flush provenance uses the exact timestamp appended to the strike history.
func containsTimestamp(list []time.Time, ts time.Time) bool {
	for _, t := range list {
		if t.Equal(ts) {
			return true
		}
	}
	return false
}

// InferenceHistory owns the shape-keyed sickness strikes and their disconnect
// provenance. Its owner serializes operations; the zero value is ready for use.
type InferenceHistory struct {
	strikes   map[modelShapeKey][]time.Time
	cooldowns map[modelShapeKey]time.Time
	flush     map[modelShapeKey][]time.Time
}

func newInferenceHistory() InferenceHistory {
	return InferenceHistory{
		strikes:   make(map[modelShapeKey][]time.Time),
		cooldowns: make(map[modelShapeKey]time.Time),
	}
}

func (h *InferenceHistory) reset() {
	clear(h.flush)
	h.strikes = make(map[modelShapeKey][]time.Time)
	h.cooldowns = make(map[modelShapeKey]time.Time)
}

// Record slides both histories on every counted strike and extends an active
// cooldown. Only a transition into cooldown returns true.
func (h *InferenceHistory) Record(model, shape string, now time.Time, flush bool) bool {
	if h.strikes == nil {
		h.strikes = make(map[modelShapeKey][]time.Time)
	}
	if h.cooldowns == nil {
		h.cooldowns = make(map[modelShapeKey]time.Time)
	}
	key := modelShapeKey{Model: model, Shape: shape}
	strikes := h.strikes[key]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < inferenceErrorWindow {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	h.strikes[key] = kept
	tags := h.flush[key]
	keptTags := tags[:0]
	for _, ts := range tags {
		if now.Sub(ts) < inferenceErrorWindow {
			keptTags = append(keptTags, ts)
		}
	}
	if len(keptTags) == 0 {
		delete(h.flush, key)
	} else {
		h.flush[key] = keptTags
	}
	if flush {
		if h.flush == nil {
			h.flush = make(map[modelShapeKey][]time.Time)
		}
		h.flush[key] = append(h.flush[key], now)
	}
	if len(kept) < inferenceErrorThreshold {
		return false
	}
	expiry, active := h.cooldowns[key]
	active = active && now.Before(expiry)
	h.cooldowns[key] = now.Add(inferenceErrorCooldownTTL)
	return !active
}

func (h *InferenceHistory) Clear(model, shape string) {
	key := modelShapeKey{Model: model, Shape: shape}
	delete(h.strikes, key)
	delete(h.cooldowns, key)
	delete(h.flush, key)
}

func (h *InferenceHistory) Cooled(model, shape string, now time.Time) bool {
	expiry, ok := h.cooldowns[modelShapeKey{Model: model, Shape: shape}]
	return ok && now.Before(expiry)
}

// Chronological returns owned copies of the ordered strike and provenance
// histories. Reset cleanup consumes this evidence without aliasing its edits.
func (h *InferenceHistory) Chronological(model, shape string) (strikes, flush []time.Time) {
	key := modelShapeKey{Model: model, Shape: shape}
	return append([]time.Time(nil), h.strikes[key]...), append([]time.Time(nil), h.flush[key]...)
}

// DropDisconnectFlush removes only tagged strikes and clears cooldowns whose
// surviving evidence no longer meets the sickness threshold.
func (h *InferenceHistory) DropDisconnectFlush(now time.Time) (cleared bool) {
	for key := range h.flush {
		strikes, flush := h.Chronological(key.Model, key.Shape)
		delete(h.flush, key)
		kept := h.strikes[key][:0]
		for _, stamp := range strikes {
			if !containsTimestamp(flush, stamp) {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == len(strikes) {
			continue
		}
		cleared = true
		if len(kept) == 0 {
			delete(h.strikes, key)
		} else {
			h.strikes[key] = kept
		}
		inWindow := 0
		for _, stamp := range kept {
			if now.Sub(stamp) < inferenceErrorWindow {
				inWindow++
			}
		}
		if inWindow < inferenceErrorThreshold {
			delete(h.cooldowns, key)
		}
	}
	return cleared
}

// Merge preserves timestamp multiplicity and the later cooldown deadline.
// The source is retired/reset by the owning identity migration after merging.
func (h *InferenceHistory) Merge(src *InferenceHistory) {
	if src == nil {
		return
	}
	if h.strikes == nil {
		h.strikes = make(map[modelShapeKey][]time.Time)
	}
	if h.cooldowns == nil {
		h.cooldowns = make(map[modelShapeKey]time.Time)
	}
	if len(src.flush) > 0 && h.flush == nil {
		h.flush = make(map[modelShapeKey][]time.Time)
	}
	for key, stamps := range src.flush {
		h.flush[key] = MergeChronologicalTimestamps(h.flush[key], stamps)
	}
	for key, stamps := range src.strikes {
		h.strikes[key] = MergeChronologicalTimestamps(h.strikes[key], stamps)
	}
	for key, expiry := range src.cooldowns {
		if cur, ok := h.cooldowns[key]; !ok || expiry.After(cur) {
			h.cooldowns[key] = expiry
		}
	}
}

// InferenceRetention is the remaining routing evidence after maintenance.
type InferenceRetention struct {
	StrikeBuckets   int
	CooldownBuckets int
	FlushBuckets    int
}

func (r InferenceRetention) Idle() bool { return r.StrikeBuckets+r.CooldownBuckets == 0 }

// Prune removes expired buckets; it does not compact still-live histories or
// erase node-level half-open memory. The result feeds the identity idle policy.
func (h *InferenceHistory) Prune(now time.Time) InferenceRetention {
	for key, expiry := range h.cooldowns {
		if !now.Before(expiry) {
			delete(h.cooldowns, key)
		}
	}
	for key, strikes := range h.strikes {
		if len(strikes) == 0 || !strikes[len(strikes)-1].Add(inferenceErrorWindow).After(now) {
			delete(h.strikes, key)
			delete(h.flush, key)
		}
	}
	return InferenceRetention{StrikeBuckets: len(h.strikes), CooldownBuckets: len(h.cooldowns), FlushBuckets: len(h.flush)}
}
