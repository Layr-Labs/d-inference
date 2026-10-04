package attempt

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
)

type SelectionResult struct {
	Outcome  Outcome
	Terminal retry.TerminalPolicy
}

// LoopOperations retain the request owner's transport, settlement and response
// authority. The loop alone decides whether another attempt may start.
type LoopOperations struct {
	Begin           func(int)
	Expired         func() bool
	Deadline        func()
	ResetPreamble   func()
	Dispatch        func() SelectionResult
	Ready           func()
	ExpiredInflight func() Outcome
	FirstContent    func() Outcome
	Accepted        func() Outcome
	RetryDecision   func() retry.Decision
	ClientGone      func()
}

type LoopResult struct {
	LastAttempt int
	Outcome     Outcome
	Terminal    retry.TerminalPolicy
	Retry       retry.Decision
}

type Loop struct {
	operations LoopOperations
	limit      int
}

func NewLoop(operations LoopOperations, limit int) *Loop {
	return &Loop{operations: operations, limit: limit}
}

func (l *Loop) Run(ctx context.Context) LoopResult {
	result := LoopResult{Outcome: FailFast}
	op := l.operations
	for index := range l.limit {
		result.LastAttempt = index
		op.Begin(index)
		if index > 0 && ctx.Err() != nil {
			op.ClientGone()
			result.Outcome = ClientGone
			return result
		}
		if index > 0 && op.Expired() {
			op.Deadline()
			return result
		}
		op.ResetPreamble()
		selected := op.Dispatch()
		result.Terminal = selected.Terminal
		switch out := selected.Outcome; out {
		case Retry:
			continue
		case FailFast, ResponseWritten, ClientGone:
			result.Outcome = out
			return result
		}
		op.Ready()
		if op.Expired() {
			switch out := op.ExpiredInflight(); out {
			case Committed, FailFast:
				result.Outcome = out
				return result
			}
		}
		switch out := op.FirstContent(); out {
		case Retry:
			result.Retry = op.RetryDecision()
			result.Terminal = terminalPolicy(result.Retry)
			if result.Retry.Stop {
				return result
			}
			continue
		case ClientGone:
			result.Outcome = out
			return result
		case Accepted:
			switch out := op.Accepted(); out {
			case Retry:
				result.Retry = op.RetryDecision()
				result.Terminal = terminalPolicy(result.Retry)
				if result.Retry.Stop {
					return result
				}
				continue
			case ClientGone:
				result.Outcome = out
				return result
			default:
				result.Outcome = out
			}
		default:
			result.Outcome = out
		}
		return result
	}
	return result
}

func terminalPolicy(decision retry.Decision) retry.TerminalPolicy {
	return retry.TerminalPolicy{
		ClientError: decision.ClientStatusCode != 0, ClientStatus: decision.ClientStatusCode,
		ClientReason: decision.ClientReason, Unservable: decision.UnservableReason != "",
		UnservableReason: decision.UnservableReason,
	}
}
