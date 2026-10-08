// Package autopilotrewards settles Autopilot's daily inference-earnings floor.
// Enrollment, money and retry ownership live in the durable store, not a live
// registry snapshot or the ordinary base-reward engine.
package autopilotrewards

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

const (
	pageSize      = 100
	catchUpDays   = 31
	retryInterval = time.Minute
)

type Engine struct {
	store  store.Store
	logger *slog.Logger
	now    func() time.Time
}

func NewEngine(st store.Store, logger *slog.Logger, now func() time.Time) *Engine {
	if logger == nil {
		logger = slog.Default()
	}
	if now == nil {
		now = time.Now
	}
	return &Engine{store: st, logger: logger, now: now}
}

// Result counts work attempted, not newly credited money: another coordinator
// can have finalized a listed day before this worker reaches its receipt.
type Result struct {
	ProcessedDays  int
	PoolPending    int
	HistoryPending int
	Failed         int
	More           bool
}

// SettleClosedDays catches up bounded, chronological work per machine. The store
// rechecks consent as of each UTC close, canonical identity, money and the cap
// atomically. A delayed worker never substitutes today's opt-in state or income.
func (e *Engine) SettleClosedDays(ctx context.Context) (Result, error) {
	var result Result
	st, ok := store.As[store.AutopilotRewardsStore](e.store)
	if !ok {
		return result, errors.New("Autopilot reward store unavailable")
	}
	closedBefore := floorpolicy.Day(e.now())
	if end := floorpolicy.EndsAt(); closedBefore.After(end) {
		closedBefore = end
	}
	var firstErr error
	for after := ""; ; {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		page, err := st.AutopilotRewardEnrollments(ctx, after, pageSize)
		if err != nil {
			return result, err
		}
		for _, enrollment := range page {
			if enrollment.NextDay.IsZero() || !enrollment.NextDay.Before(closedBefore) {
				continue
			}
			if !enrollment.BaselineKnown || enrollment.HistoryConflict {
				result.HistoryPending++
				continue
			}
			day := enrollment.NextDay
			for n := 0; n < catchUpDays && day.Before(closedBefore); n++ {
				callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
				settlement, err := st.SettleAutopilotRewardDay(callCtx, enrollment.MachineID, day)
				cancel()
				if err != nil {
					result.Failed++
					if firstErr == nil {
						firstErr = err
					}
					break
				}
				switch settlement.Status {
				case earningsfloor.PoolExhausted:
					result.PoolPending++
				case earningsfloor.HistoryRequired:
					result.HistoryPending++
				case earningsfloor.Paid, earningsfloor.Zero, earningsfloor.OptedOut:
					result.ProcessedDays++
					day = day.AddDate(0, 0, 1)
					continue
				default:
					result.Failed++
					if firstErr == nil {
						firstErr = errors.New("unknown Autopilot reward settlement status")
					}
				}
				break
			}
			result.More = result.More || day.Before(closedBefore)
		}
		if len(page) < pageSize {
			return result, firstErr
		}
		after = page[len(page)-1].MachineID
	}
}

// Run settles immediately on startup, then at midnight UTC. Pending money,
// history repairs and bounded catch-up retry without waiting another day.
func (e *Engine) Run(ctx context.Context) {
	for ctx.Err() == nil {
		result, err := e.SettleClosedDays(ctx)
		if ctx.Err() != nil {
			return
		}
		if result.ProcessedDays > 0 || result.PoolPending > 0 || result.HistoryPending > 0 || err != nil {
			// Store errors can contain database values; logs carry only aggregate
			// operational counts, never machine/account identifiers or evidence.
			e.logger.Info("Autopilot rewards settlement",
				"processed_days", result.ProcessedDays,
				"pool_pending", result.PoolPending,
				"history_pending", result.HistoryPending,
				"failed", result.Failed, "store_error", err != nil)
		}
		now := e.now()
		wait := floorpolicy.Day(now).AddDate(0, 0, 1).Sub(now)
		if result.More || result.HistoryPending > 0 || err != nil {
			wait = min(wait, retryInterval)
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
