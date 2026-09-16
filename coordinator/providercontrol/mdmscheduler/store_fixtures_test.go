package mdmscheduler

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type cancelAwareVerificationStore struct {
	*store.MemoryStore
}

func (s *cancelAwareVerificationStore) ReleaseVerificationJob(
	ctx context.Context,
	seKey string,
	kind store.VerificationTaskKind,
	owner string,
	now time.Time,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.MemoryStore.ReleaseVerificationJob(ctx, seKey, kind, owner, now)
}

type releaseFailingVerificationStore struct {
	*store.MemoryStore
}

func (s *releaseFailingVerificationStore) ReleaseVerificationJob(
	context.Context,
	string,
	store.VerificationTaskKind,
	string,
	time.Time,
) error {
	return fmt.Errorf("release unavailable")
}
