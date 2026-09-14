package providerversion

import "strings"

// SlotBudgetLayout identifies whether slots report shared headroom or private grants.
type SlotBudgetLayout uint8

const (
	SharedSlotHeadroom SlotBudgetLayout = iota
	PrivateSlotGrants
	privateSlotGrantsMinVersion = "0.7.5"
)

// SlotBudgetLayout selects the pooled-budget layout for a provider
// binary version. It runs once per provider per routing scan via
// fillSnapshotPendingAndPool, so the result is memoized (memo.go) —
// keyed on the NORMALIZED numeric core ("1.0.0" for "v1.0.0-rc1+meta"), so
// suffix variants of one version share an entry and an oversized suffix can
// never be retained; a core longer than maxMemoizedVersionLen is computed
// without caching.
func (p *Policy) SlotBudgetLayout(version string) SlotBudgetLayout {
	return p.slotBudgetLayoutMemo.get(NumericCore(version), p.parseSlotBudgetLayoutCore)
}

// NumericCore strips surrounding whitespace and any pre-release/build
// suffix ("-…" / "+…") from a version, leaving the dotted numeric core.
func NumericCore(version string) string {
	version = strings.TrimSpace(version)
	if suffix := strings.IndexAny(version, "-+"); suffix >= 0 {
		version = version[:suffix]
	}
	return version
}

// parseSlotBudgetLayout is the uncached selection behind
// Policy.SlotBudgetLayout: a pre-release/build suffix is ignored and the
// numeric core compared against privateSlotGrantsMinVersion.
func (p *Policy) parseSlotBudgetLayout(version string) SlotBudgetLayout {
	return p.parseSlotBudgetLayoutCore(NumericCore(version))
}

// parseSlotBudgetLayoutCore compares an already-normalized numeric core.
func (p *Policy) parseSlotBudgetLayoutCore(core string) SlotBudgetLayout {
	if p.Compare(core, privateSlotGrantsMinVersion) >= 0 {
		return PrivateSlotGrants
	}
	return SharedSlotHeadroom
}
