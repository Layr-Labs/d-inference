package registry

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"time"
)

// NativeRuntimeCatalogSchema names the operator's approval file format.
const NativeRuntimeCatalogSchema = "darkbloom_cluster_pair_catalog_v1"

const nativeRuntimeCatalogFileLimit = 1 << 20

type nativeRuntimeCatalogFile struct {
	Schema    string                      `json:"schema"`
	Approvals []nativeRuntimeApprovalFile `json:"approvals"`
}

// Every field is required. The canonical policy bytes a member compares are
// built from these values, so nothing here has a default.
type nativeRuntimeApprovalFile struct {
	ID                         string   `json:"id"`
	Model                      string   `json:"model"`
	Generation                 uint64   `json:"generation"`
	PlanSHA256                 string   `json:"plan_sha256"`
	ArtifactSHA256             string   `json:"artifact_sha256"`
	NativeRuntimeSHA256        string   `json:"native_runtime_sha256"`
	MetallibSHA256             string   `json:"metallib_sha256"`
	ResourceLibrarySHA256      string   `json:"resource_library_sha256"`
	CapabilitySHA256           string   `json:"capability_sha256"`
	ResourcePolicySHA256       string   `json:"resource_policy_sha256"`
	ProfileSHA256              string   `json:"profile_sha256"`
	Schedule                   uint8    `json:"schedule"`
	MaximumTransportFrame      uint32   `json:"maximum_transport_frame"`
	MaximumPlaintext           uint32   `json:"maximum_plaintext"`
	MaximumRecords             uint64   `json:"maximum_records"`
	MaximumCumulativePlaintext uint64   `json:"maximum_cumulative_plaintext"`
	AllowedChips               []string `json:"allowed_chips"`
	NotAfter                   string   `json:"not_after"`
}

// ParseNativeRuntimeCatalog reads the operator's reviewed approval file. It is
// the only way configuration becomes a catalog: unknown fields, trailing data,
// a missing schema, an empty approval list and every bound NewNativeRuntimeCatalog
// enforces are errors, so a mistyped file never enables a weaker policy.
func ParseNativeRuntimeCatalog(data []byte) (*NativeRuntimeCatalog, error) {
	if len(data) > nativeRuntimeCatalogFileLimit {
		return nil, fmt.Errorf("%w: catalog file exceeds %d bytes", ErrNativePairApproval, nativeRuntimeCatalogFileLimit)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var file nativeRuntimeCatalogFile
	if err := decoder.Decode(&file); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrNativePairApproval, err)
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, fmt.Errorf("%w: trailing data after the catalog document", ErrNativePairApproval)
	}
	if file.Schema != NativeRuntimeCatalogSchema {
		return nil, fmt.Errorf("%w: schema must be %q", ErrNativePairApproval, NativeRuntimeCatalogSchema)
	}
	if len(file.Approvals) == 0 {
		return nil, fmt.Errorf("%w: catalog approves nothing", ErrNativePairApproval)
	}
	approvals := make([]NativeRuntimeApproval, 0, len(file.Approvals))
	for index, entry := range file.Approvals {
		approval, err := entry.approval()
		if err != nil {
			return nil, fmt.Errorf("%w: approval %d (%q): %v", ErrNativePairApproval, index, entry.ID, err)
		}
		approvals = append(approvals, approval)
	}
	catalog, err := NewNativeRuntimeCatalog(approvals)
	if err != nil {
		return nil, fmt.Errorf("%w: an approval is out of bounds or duplicated", err)
	}
	return catalog, nil
}

func (f nativeRuntimeApprovalFile) approval() (NativeRuntimeApproval, error) {
	approval := NativeRuntimeApproval{
		ID: f.ID, Model: f.Model, Generation: f.Generation, Schedule: f.Schedule,
		MaximumTransportFrame: f.MaximumTransportFrame, MaximumPlaintext: f.MaximumPlaintext,
		MaximumRecords: f.MaximumRecords, MaximumCumulativePlaintext: f.MaximumCumulativePlaintext,
		AllowedChips: append([]string(nil), f.AllowedChips...),
	}
	notAfter, err := time.Parse(time.RFC3339, f.NotAfter)
	if err != nil {
		return NativeRuntimeApproval{}, fmt.Errorf("not_after must be RFC 3339")
	}
	approval.NotAfter = notAfter
	digests := []struct {
		name  string
		value string
		into  *[32]byte
	}{
		{"plan_sha256", f.PlanSHA256, &approval.PlanSHA256},
		{"artifact_sha256", f.ArtifactSHA256, &approval.ArtifactSHA256},
		{"native_runtime_sha256", f.NativeRuntimeSHA256, &approval.NativeRuntimeSHA256},
		{"metallib_sha256", f.MetallibSHA256, &approval.MetallibSHA256},
		{"resource_library_sha256", f.ResourceLibrarySHA256, &approval.ResourceLibrarySHA256},
		{"capability_sha256", f.CapabilitySHA256, &approval.CapabilitySHA256},
		{"resource_policy_sha256", f.ResourcePolicySHA256, &approval.ResourcePolicySHA256},
		{"profile_sha256", f.ProfileSHA256, &approval.ProfileSHA256},
	}
	for _, digest := range digests {
		decoded, err := hex.DecodeString(digest.value)
		if err != nil || len(decoded) != 32 || hex.EncodeToString(decoded) != digest.value {
			return NativeRuntimeApproval{}, fmt.Errorf("%s must be 64 lowercase hex characters", digest.name)
		}
		copy(digest.into[:], decoded)
	}
	return approval, nil
}

// PolicySHA256 returns the lowercase hex commitment of an approval's canonical
// policy bytes: the value a member registers as cluster_membership.policy_sha256
// and the binding carried in every authorization start. ok is false for an
// unknown approval ID.
func (c *NativeRuntimeCatalog) PolicySHA256(approvalID string) (string, bool) {
	if c == nil {
		return "", false
	}
	entry, ok := c.entries[approvalID]
	if !ok {
		return "", false
	}
	return hex.EncodeToString(entry.binding[:]), true
}
