package ttftcalibration

import "time"

const (
	PendingTTL            = 10 * time.Minute
	MaxPending            = 8192
	SweepThreshold        = 1024
	SweepInterval         = time.Minute
	CapacitySweepInterval = 5 * time.Second
	EvictProbe            = 8
)

// PendingID avoids allocation and delimiter collisions on the reservation path.
type PendingID struct {
	RequestID string
	Attempt   int
}

type Prediction struct {
	Model string
	Chip  string
	RawMs float64
	At    time.Time
}

// SweepSchedule is an opaque, comparable record of whole-map maintenance.
// Its owner serializes access with pending-prediction operations.
type SweepSchedule struct {
	lastSweep time.Time
}

func (s *SweepSchedule) Due(now time.Time, size int) bool {
	sinceSweep := now.Sub(s.lastSweep)
	return size > SweepThreshold &&
		(sinceSweep > SweepInterval ||
			(size >= MaxPending && sinceSweep > CapacitySweepInterval))
}

func (s *SweepSchedule) Swept(now time.Time) { s.lastSweep = now }

// PendingPredictions owns the bounded prediction join. The calibrator holds its
// lock across maintenance and insertion, or across taking and learning a sample.
// Retained owners must not use these operations concurrently with the calibrator.
type PendingPredictions struct {
	predictions map[PendingID]Prediction
	schedule    *SweepSchedule
}

func NewPendingPredictions(schedule *SweepSchedule) *PendingPredictions {
	if schedule == nil {
		schedule = &SweepSchedule{}
	}
	return &PendingPredictions{predictions: make(map[PendingID]Prediction), schedule: schedule}
}

func (p *PendingPredictions) Put(key PendingID, prediction Prediction) {
	p.predictions[key] = prediction
}

func (p *PendingPredictions) Take(key PendingID) (Prediction, bool) {
	prediction, ok := p.predictions[key]
	if ok {
		delete(p.predictions, key)
	}
	return prediction, ok
}

func (p *PendingPredictions) reset() {
	p.predictions = make(map[PendingID]Prediction)
}

// Maintain frees room for one insertion. Whole-map TTL sweeps are rate limited;
// between sweeps a full map probes at most EvictProbe entries, preferring the
// first expired entry and otherwise dropping the last probed entry.
func (p *PendingPredictions) Maintain(now time.Time) {
	if p.schedule.Due(now, len(p.predictions)) {
		p.schedule.Swept(now)
		for key, prediction := range p.predictions {
			if now.Sub(prediction.At) > PendingTTL {
				delete(p.predictions, key)
			}
		}
		for key := range p.predictions {
			if len(p.predictions) < MaxPending {
				break
			}
			delete(p.predictions, key)
		}
	}
	if len(p.predictions) >= MaxPending {
		var last PendingID
		probed := 0
		for key, prediction := range p.predictions {
			if now.Sub(prediction.At) > PendingTTL {
				delete(p.predictions, key)
				return
			}
			last = key
			probed++
			if probed >= EvictProbe {
				break
			}
		}
		if probed > 0 {
			delete(p.predictions, last)
		}
	}
}
