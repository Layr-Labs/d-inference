package registry

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"math"
	"sort"
	"time"
	"unicode/utf8"
)

var ErrNativePairApproval = errors.New("native pair runtime is not explicitly approved")
var ErrNativePairControl = errors.New("native pair control binding refused")

// Supplied only by trusted coordinator startup configuration, never by a
// provider message or the model capability table. Approval of this closed
// native arithmetic/resource policy does NOT relax ordinary model eligibility.
// In particular it neither invents mlx_nax nor renames the 27B model.
type NativeRuntimeApproval struct {
	ID, Model                                                                              string
	Generation                                                                             uint64
	PlanSHA256, ArtifactSHA256, NativeRuntimeSHA256, MetallibSHA256, ResourceLibrarySHA256 [32]byte
	CapabilitySHA256, ResourcePolicySHA256, ProfileSHA256                                  [32]byte
	Schedule                                                                               uint8
	MaximumTransportFrame, MaximumPlaintext                                                uint32
	MaximumRecords, MaximumCumulativePlaintext                                             uint64
	AllowedChips                                                                           []string
	NotAfter                                                                               time.Time
}
type nativeApprovedRuntime struct {
	policy    NativeRuntimeApproval
	canonical []byte
	binding   [32]byte
}
type NativeRuntimeCatalog struct {
	entries map[string]nativeApprovedRuntime
}

// The returned catalog owns defensive copies; there is no wire upsert and no
// mutable public entry. Nil/empty remains disabled. Revocation is one-way per
// running coordinator; replacement requires a fresh explicitly approved entry.
func NewNativeRuntimeCatalog(policies []NativeRuntimeApproval) (*NativeRuntimeCatalog, error) {
	if len(policies) > 64 {
		return nil, ErrNativePairApproval
	}
	c := &NativeRuntimeCatalog{entries: make(map[string]nativeApprovedRuntime, len(policies))}
	for _, p := range policies {
		p.AllowedChips = append([]string(nil), p.AllowedChips...)
		b, e := canonicalNativeRuntimeApproval(p)
		if e != nil {
			return nil, e
		}
		if _, ok := c.entries[p.ID]; ok {
			return nil, ErrNativePairApproval
		}
		c.entries[p.ID] = nativeApprovedRuntime{p, b, sha256.Sum256(b)}
	}
	return c, nil
}

// canonicalNativeRuntimeApproval encodes the policy bytes both members compare
// and hash. The provider derives the same bytes from its saved copy of the
// entry (ClusterPairApproval.canonicalPolicy) and reads them back with a strict
// reader (NativePairMemberPolicy), so this refuses everything either refuses:
// text that is not valid UTF-8, chip names outside printable ASCII (where byte
// order and the provider's string order and equality could disagree), and an
// expiry that is not a positive count of nanoseconds since 1970 in an int64.
func canonicalNativeRuntimeApproval(p NativeRuntimeApproval) ([]byte, error) {
	expiry, representable := approvalExpiryNanoseconds(p.NotAfter)
	if len(p.ID) == 0 || len(p.ID) > 128 || len(p.Model) == 0 || len(p.Model) > 512 || !utf8.ValidString(p.ID) || !utf8.ValidString(p.Model) ||
		p.Generation == 0 || !representable || len(p.AllowedChips) == 0 || len(p.AllowedChips) > 16 || !sort.StringsAreSorted(p.AllowedChips) {
		return nil, ErrNativePairApproval
	}
	if (p.Schedule != 1 && p.Schedule != 2) || p.MaximumPlaintext == 0 || p.MaximumPlaintext > 16*1024*1024 || p.MaximumTransportFrame < p.MaximumPlaintext+40 || p.MaximumTransportFrame > 16*1024*1024+40 || p.MaximumRecords == 0 || p.MaximumRecords > 1048576 || p.MaximumCumulativePlaintext == 0 || p.MaximumCumulativePlaintext > 4*1024*1024*1024 {
		return nil, ErrNativePairApproval
	}
	b := []byte("darkbloom/coordinator-native-runtime-approval/v1\x00")
	add := func(s string) { b = binary.BigEndian.AppendUint32(b, uint32(len(s))); b = append(b, s...) }
	add(p.ID)
	add(p.Model)
	b = binary.BigEndian.AppendUint64(b, p.Generation)
	for _, h := range [][32]byte{p.PlanSHA256, p.ArtifactSHA256, p.NativeRuntimeSHA256, p.MetallibSHA256, p.ResourceLibrarySHA256, p.CapabilitySHA256, p.ResourcePolicySHA256, p.ProfileSHA256} {
		if h == [32]byte{} {
			return nil, ErrNativePairApproval
		}
		b = append(b, h[:]...)
	}
	b = append(b, 1, 1, p.Schedule)
	b = binary.BigEndian.AppendUint32(b, p.MaximumTransportFrame)
	b = binary.BigEndian.AppendUint32(b, p.MaximumPlaintext)
	b = binary.BigEndian.AppendUint64(b, p.MaximumRecords)
	b = binary.BigEndian.AppendUint64(b, p.MaximumCumulativePlaintext)
	b = binary.BigEndian.AppendUint64(b, expiry)
	b = binary.BigEndian.AppendUint32(b, uint32(len(p.AllowedChips)))
	for i, chip := range p.AllowedChips {
		if len(chip) == 0 || len(chip) > 128 || !printableASCII(chip) || (i > 0 && p.AllowedChips[i-1] == chip) {
			return nil, ErrNativePairApproval
		}
		add(chip)
	}
	return b, nil
}

// approvalExpiryNanoseconds is an expiry as the nanoseconds since 1970 the
// canonical policy carries. ok is false at or before the first second of 1970
// and beyond what an int64 of nanoseconds holds.
func approvalExpiryNanoseconds(t time.Time) (nanoseconds uint64, ok bool) {
	seconds, fraction := t.Unix(), int64(t.Nanosecond())
	if seconds <= 0 || seconds > (math.MaxInt64-fraction)/int64(time.Second) {
		return 0, false
	}
	return uint64(seconds)*uint64(time.Second) + uint64(fraction), true
}

func printableASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}
