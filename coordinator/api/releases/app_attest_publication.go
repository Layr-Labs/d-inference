package releases

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var errBuildQualificationUnavailable = errors.New("build qualification storage unavailable")

// Called only after the final artifact has been independently downloaded and
// verified. Approval is a separate admin operation; CI cannot manufacture it.
func (s *Owner) persistReleaseForPublication(ctx context.Context, release store.Release, req registerReleaseRequest) error {
	if !s.requiresAppAttestPublication() && !req.RequireAppAttestQualification {
		return s.store.SetRelease(&release)
	}
	build := store.AppAttestBuildIdentity{Release: release, CodeDirectoryHash: req.CodeDirectoryHash, SourceCommit: req.SourceCommit, CIRunID: req.CIRunID}
	if err := build.Validate(); err != nil {
		return fmt.Errorf("%w: %v", store.ErrBuildNotQualified, err)
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		return errBuildQualificationUnavailable
	}
	op, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.hooks.AppAttest().RefreshBuildQualifications(op); err != nil {
		return fmt.Errorf("%w: %v", errBuildQualificationUnavailable, err)
	}
	if !s.hooks.AppAttest().BuildReady(build) {
		return store.ErrBuildNotQualified
	}
	// The local readiness check is necessary, but insufficient: this atomic
	// store operation also checks approval under the row lock used by revocation.
	return st.SetQualifiedRelease(op, build)
}
