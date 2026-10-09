package registry

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"slices"
	"time"
)

// NativeRuntimeCatalogSchema names the operator's approval file format.
const NativeRuntimeCatalogSchema = "darkbloom_cluster_pair_catalog_v1"

const nativeRuntimeCatalogFileLimit = 1 << 20

type nativeRuntimeCatalogFile struct {
	Schema    string            `json:"schema"`
	Approvals []json.RawMessage `json:"approvals"`
}

// approvalInstantSyntax is the only form of not_after both sides read the same
// way: an RFC 3339 instant with upper-case T, an optional fraction of one to
// nine digits, and a zone of Z or a signed HH:MM offset. Go's own RFC 3339
// parser is laxer (a comma, more digits, a one-digit hour) and the provider
// refuses those forms outright.
var approvalInstantSyntax = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$`)

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
	if err := exactFieldNames(data, "schema", "approvals"); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrNativePairApproval, err)
	}
	if file.Schema != NativeRuntimeCatalogSchema {
		return nil, fmt.Errorf("%w: schema must be %q", ErrNativePairApproval, NativeRuntimeCatalogSchema)
	}
	if len(file.Approvals) == 0 {
		return nil, fmt.Errorf("%w: catalog approves nothing", ErrNativePairApproval)
	}
	approvals := make([]NativeRuntimeApproval, 0, len(file.Approvals))
	for index, raw := range file.Approvals {
		var entry nativeRuntimeApprovalFile
		entryDecoder := json.NewDecoder(bytes.NewReader(raw))
		entryDecoder.DisallowUnknownFields()
		err := entryDecoder.Decode(&entry)
		if err == nil {
			err = exactFieldNames(raw, nativeRuntimeApprovalFields...)
		}
		var approval NativeRuntimeApproval
		if err == nil {
			approval, err = entry.approval()
		}
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
	notAfter, ok := parseApprovalInstant(f.NotAfter)
	if !ok {
		return NativeRuntimeApproval{}, fmt.Errorf("not_after must be an RFC 3339 instant: YYYY-MM-DDTHH:MM:SS, an optional fraction of 1-9 digits, then Z or ±HH:MM")
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

var nativeRuntimeApprovalFields = []string{"id", "model", "generation", "plan_sha256", "artifact_sha256",
	"native_runtime_sha256", "metallib_sha256", "resource_library_sha256", "capability_sha256",
	"resource_policy_sha256", "profile_sha256", "schedule", "maximum_transport_frame", "maximum_plaintext",
	"maximum_records", "maximum_cumulative_plaintext", "allowed_chips", "not_after"}

// exactFieldNames refuses a JSON object with a member name that is not one of
// allowed, spelled exactly, or that appears twice. Go's decoder matches names
// without regard to case and keeps the last of a repeated name; the provider's
// reader of the same entry does neither.
func exactFieldNames(object []byte, allowed ...string) error {
	decoder := json.NewDecoder(bytes.NewReader(object))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return fmt.Errorf("a JSON object is required")
	}
	seen := make(map[string]bool, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		name, isName := token.(string)
		if err != nil || !isName || !slices.Contains(allowed, name) || seen[name] {
			return fmt.Errorf("field %q is misspelled, unknown or repeated", name)
		}
		seen[name] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
	}
	return nil
}

// parseApprovalInstant reads not_after in the one form both sides accept.
func parseApprovalInstant(text string) (time.Time, bool) {
	if !approvalInstantSyntax.MatchString(text) {
		return time.Time{}, false
	}
	if zone := text[len(text)-6:]; zone[0] == '+' || zone[0] == '-' {
		if zone[1:3] > "23" || zone[4:6] > "59" {
			return time.Time{}, false
		}
	}
	instant, err := time.Parse(time.RFC3339Nano, text)
	return instant, err == nil
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
