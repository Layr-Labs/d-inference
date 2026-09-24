package api

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var errBuildQualificationUnavailable = errors.New("build qualification storage unavailable")

// appAttestBuildIdentityFromRequest builds the identity used for both
// publication and the read-only POST /v1/releases/qualification status check,
// so the two endpoints can never diverge on what "the same identity" means.
func appAttestBuildIdentityFromRequest(release store.Release, req registerReleaseRequest) store.AppAttestBuildIdentity {
	return store.AppAttestBuildIdentity{Release: release, CodeDirectoryHash: req.CodeDirectoryHash, SourceCommit: req.SourceCommit, CIRunID: req.CIRunID}
}

// Called only after the final artifact has been independently downloaded and
// verified. Approval is a separate admin operation; CI cannot manufacture it.
func (s *Server) persistReleaseForPublication(ctx context.Context, release store.Release, req registerReleaseRequest) error {
	if !s.requiresAppAttestPublication() && !req.RequireAppAttestQualification {
		return s.store.SetRelease(&release)
	}
	build := appAttestBuildIdentityFromRequest(release, req)
	if err := build.Validate(); err != nil {
		return fmt.Errorf("%w: %v", store.ErrBuildNotQualified, err)
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		return errBuildQualificationUnavailable
	}
	op, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.appAttestFeature().RefreshBuildQualifications(op); err != nil {
		return fmt.Errorf("%w: %v", errBuildQualificationUnavailable, err)
	}
	if !s.appAttestFeature().BuildReady(build) {
		return store.ErrBuildNotQualified
	}
	// The local readiness check is necessary, but insufficient: this atomic
	// store operation also checks approval under the row lock used by revocation.
	return st.SetQualifiedRelease(op, build)
}
