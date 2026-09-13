package store

import (
	"context"
	"sort"
	"time"
)

func (s *MemoryStore) RedactSandboxCommandPayloads(ctx context.Context, completedBefore, redactedAt time.Time, limit int) (int, error) {
	if completedBefore.IsZero() || redactedAt.IsZero() || redactedAt.Before(completedBefore) {
		return 0, ErrSandboxInvalidTransition
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	eligible := make([]*SandboxCommand, 0)
	for _, command := range s.sandboxCommands {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		if command.Terminal() && !command.CancellationPending && !command.PayloadExpired &&
			command.CompletedAt != nil && !command.CompletedAt.After(completedBefore) {
			eligible = append(eligible, command)
		}
	}
	sort.Slice(eligible, func(i, j int) bool {
		if eligible[i].CompletedAt.Equal(*eligible[j].CompletedAt) {
			return eligible[i].ID < eligible[j].ID
		}
		return eligible[i].CompletedAt.Before(*eligible[j].CompletedAt)
	})
	if limit = sandboxPayloadRedactionLimit(limit); len(eligible) > limit {
		eligible = eligible[:limit]
	}
	redacted := make([]*SandboxCommand, 0, len(eligible))
	for _, command := range eligible {
		clone := cloneSandboxCommand(command)
		if err := redactSandboxCommandPayload(clone, redactedAt); err != nil {
			return 0, err
		}
		redacted = append(redacted, clone)
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	for _, command := range redacted {
		s.sandboxCommands[command.ID] = command
	}
	return len(redacted), nil
}
