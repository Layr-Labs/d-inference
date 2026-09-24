package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// releaseQualificationStatusResponse is the POST /v1/releases/qualification
// response body (CONTRACT.md #1177 C1). Timestamps are RFC3339 UTC; empty
// fields are omitted. approved_by/approved_at/evidence and revoked_*/
// mismatched_fields are populated only for the statuses that carry them.
type releaseQualificationStatusResponse struct {
	Status           string   `json:"status"`
	BinaryHash       string   `json:"binary_hash,omitempty"`
	ApprovedBy       string   `json:"approved_by,omitempty"`
	ApprovedAt       string   `json:"approved_at,omitempty"`
	Evidence         string   `json:"evidence,omitempty"`
	RevokedAt        string   `json:"revoked_at,omitempty"`
	RevokedBy        string   `json:"revoked_by,omitempty"`
	RevocationReason string   `json:"revocation_reason,omitempty"`
	MismatchedFields []string `json:"mismatched_fields,omitempty"`
}

// handleReleaseQualificationStatus handles POST /v1/releases/qualification.
// It never writes the build qualification store or the release catalog and
// never registers a release. Like registration, it refreshes the in-memory
// qualification snapshot from the durable store before answering. Auth and body
// decoding intentionally mirror handleRegisterRelease (release_handlers.go,
// owned by a different #1177 track) byte for byte; the ~15 line decode block
// is duplicated rather than shared to keep that handler's behavior untouched
// and avoid cross-track edits.
func (s *Server) handleReleaseQualificationStatus(w http.ResponseWriter, r *http.Request) {
	token := extractBearerToken(r)
	if !s.releaseKeyAuthorized(token) {
		writeJSON(w, http.StatusUnauthorized, errorResponse("unauthorized", "invalid release key"))
		return
	}

	var req registerReleaseRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxReleaseRegisterBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: multiple JSON values"))
		return
	}

	release := req.toRelease()
	if release.Platform == "" {
		release.Platform = defaultReleasePlatform
	}
	build := appAttestBuildIdentityFromRequest(release, req)
	if err := build.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}

	// RefreshBuildQualifications itself fails when the store does not
	// implement store.AppAttestBuildStore, so a single error path covers both
	// "no such capability" and "read failed" (CONTRACT.md C1: both are 503
	// qualification_unavailable).
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.appAttestFeature().RefreshBuildQualifications(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("qualification_unavailable", "qualification refresh failed"))
		return
	}

	resp := releaseQualificationStatusResponse{BinaryHash: build.Release.BinaryHash}
	row, found := s.appAttestFeature().BuildQualificationSnapshot(build.Release.BinaryHash)
	switch {
	case found && !row.RevokedAt.IsZero():
		// Revocation is keyed by binary hash and wins over every other
		// identity field (precedence #1). FenceBuild can create a tombstone
		// row with only BinaryHash and RevokedAt set and no approval ever
		// recorded, so approved_by/approved_at/evidence stay empty (and thus
		// omitted) in that case.
		resp.Status = "revoked"
		resp.RevokedAt = row.RevokedAt.UTC().Format(time.RFC3339)
		resp.RevokedBy = row.RevokedBy
		resp.RevocationReason = row.RevocationReason
		resp.ApprovedBy = row.ApprovedBy
		if !row.ApprovedAt.IsZero() {
			resp.ApprovedAt = row.ApprovedAt.UTC().Format(time.RFC3339)
		}
		resp.Evidence = row.Evidence
	case !found:
		resp.Status = "pending"
	case !row.Matches(build) || row.AppAttestBuildIdentity.Validate() != nil:
		resp.Status = "mismatched"
		if row.AppAttestBuildIdentity.Validate() != nil {
			// The stored row itself is malformed. This should be unreachable
			// since both approval (validateApproval) and this handler's own
			// pre-check validate on write/read, but a row born from an old
			// schema or a partial write must fail closed rather than ever
			// report "approved" for an identity that cannot be trusted. Report
			// one synthetic field: a broken row need not differ from the
			// request on any of the nine identity fields below.
			resp.MismatchedFields = []string{"identity"}
		} else {
			resp.MismatchedFields = mismatchedFields(row.AppAttestBuildIdentity, build)
		}
	default:
		resp.Status = "approved"
		resp.ApprovedBy = row.ApprovedBy
		resp.ApprovedAt = row.ApprovedAt.UTC().Format(time.RFC3339)
		resp.Evidence = row.Evidence
	}
	writeJSON(w, http.StatusOK, resp)
}

// mismatchedFields compares the stored qualification row's identity against
// the requested identity, field by field, per CONTRACT.md C1: version,
// platform, backend, bundle_hash, metallib_hash, url, code_directory_hash,
// source_commit, ci_run_id (sorted). binary_hash is excluded because the row
// is looked up BY binary_hash, so it can never differ here. PythonHash/
// RuntimeHash/TemplateHashes are excluded because AppAttestBuildIdentity.Validate
// requires both identities to leave them empty, so they can never distinguish
// a mismatch. Changelog/CreatedAt/Active are excluded because sameBuildRelease
// (coordinator/store/app_attest_builds.go) already treats them as non-identity.
func mismatchedFields(stored, requested store.AppAttestBuildIdentity) []string {
	var fields []string
	add := func(name string, differs bool) {
		if differs {
			fields = append(fields, name)
		}
	}
	add("version", stored.Release.Version != requested.Release.Version)
	add("platform", stored.Release.Platform != requested.Release.Platform)
	add("backend", stored.Release.Backend != requested.Release.Backend)
	add("bundle_hash", stored.Release.BundleHash != requested.Release.BundleHash)
	add("metallib_hash", stored.Release.MetallibHash != requested.Release.MetallibHash)
	add("url", stored.Release.URL != requested.Release.URL)
	add("code_directory_hash", stored.CodeDirectoryHash != requested.CodeDirectoryHash)
	add("source_commit", stored.SourceCommit != requested.SourceCommit)
	add("ci_run_id", stored.CIRunID != requested.CIRunID)
	sort.Strings(fields)
	if len(fields) == 0 {
		// Guarantee: a "mismatched" status must never carry an empty field
		// list. Every field Matches()/sameBuildRelease can compare is
		// enumerated above, so this is a safety net for an invariant drift,
		// not an expected path.
		fields = []string{"release"}
	}
	return fields
}
