package store

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

var (
	ErrBuildNotQualified = errors.New("signed release has no matching active App Attest qualification")
	ErrBuildConflict     = errors.New("App Attest qualification or published release identity is immutable")
)

// AppAttestBuildIdentity binds approval to the exact final signed distribution,
// not a version label or a caller-provided code measurement alone.
type AppAttestBuildIdentity struct {
	Release           Release `json:"release"`
	CodeDirectoryHash string  `json:"code_directory_hash"`
	SourceCommit      string  `json:"source_commit"`
	CIRunID           string  `json:"ci_run_id"`
}

type AppAttestBuildQualification struct {
	AppAttestBuildIdentity
	Evidence         string    `json:"evidence"`
	ApprovedBy       string    `json:"approved_by"`
	ApprovedAt       time.Time `json:"approved_at"`
	RevokedAt        time.Time `json:"revoked_at,omitempty"`
	RevokedBy        string    `json:"revoked_by,omitempty"`
	RevocationReason string    `json:"revocation_reason,omitempty"`
}

// Optional capability, deliberately uncached by CachedStore. Both publication
// and revocation serialize on the same durable qualification row.
type AppAttestBuildStore interface {
	ListAppAttestBuildQualifications(context.Context) ([]AppAttestBuildQualification, error)
	QualifyAppAttestBuild(context.Context, AppAttestBuildQualification) (bool, error)
	RevokeAppAttestBuild(context.Context, string, string, string) (bool, error)
	SetQualifiedRelease(context.Context, AppAttestBuildIdentity) error
}

func validBuildDigest(s string, size int) bool {
	if len(s) != size || strings.ToLower(s) != s {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

func (b AppAttestBuildIdentity) Validate() error {
	r := b.Release
	if r.Version == "" || len(r.Version) > 128 || r.Platform != "macos-arm64" || r.Backend != "mlx-swift" ||
		!validBuildDigest(r.BinaryHash, 64) || !validBuildDigest(r.BundleHash, 64) || !validBuildDigest(r.MetallibHash, 64) ||
		!validBuildDigest(b.CodeDirectoryHash, 64) || !validBuildDigest(b.SourceCommit, 40) ||
		b.CIRunID == "" || len(b.CIRunID) > 32 || strings.Trim(b.CIRunID, "0123456789") != "" ||
		r.URL == "" || len(r.URL) > 2048 || r.PythonHash != "" || r.RuntimeHash != "" || r.TemplateHashes != "" {
		return errors.New("qualification requires a complete signed macos-arm64 mlx-swift release, full SHA-256 CodeDirectory measurement, source commit and CI run ID")
	}
	return nil
}

func (b AppAttestBuildIdentity) Matches(other AppAttestBuildIdentity) bool {
	return sameBuildRelease(b.Release, other.Release) && b.CodeDirectoryHash == other.CodeDirectoryHash &&
		b.SourceCommit == other.SourceCommit && b.CIRunID == other.CIRunID
}

func sameBuildRelease(a, b Release) bool {
	// Changelog, creation time and activation are not signed artifact identity.
	a.Changelog, b.Changelog = "", ""
	a.CreatedAt, b.CreatedAt = time.Time{}, time.Time{}
	a.Active, b.Active = false, false
	return a == b
}

func (q AppAttestBuildQualification) validateApproval() error {
	if err := q.AppAttestBuildIdentity.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(q.Evidence) == "" || len(q.Evidence) > 4096 || q.ApprovedBy == "" || len(q.ApprovedBy) > 256 ||
		!q.RevokedAt.IsZero() || q.RevokedBy != "" || q.RevocationReason != "" {
		return errors.New("qualification requires operator identity and test evidence; revocation is a separate operation")
	}
	return nil
}

func validateBuildRevocation(binary, actor, reason string) error {
	if !validBuildDigest(binary, 64) || actor == "" || len(actor) > 256 || strings.TrimSpace(reason) == "" || len(reason) > 4096 {
		return errors.New("revocation requires binary SHA-256, operator identity and reason")
	}
	return nil
}
