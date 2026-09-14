package registry

import "github.com/eigeninference/d-inference/coordinator/registry/providerversion"

var providerVersions = &providerversion.Policy{}

// CompareVersions retains the registry's public dotted-version comparison.
func CompareVersions(a, b string) int { return providerVersions.Compare(a, b) }

type slotBudgetLayout = providerversion.SlotBudgetLayout

const (
	sharedSlotHeadroom = providerversion.SharedSlotHeadroom
	privateSlotGrants  = providerversion.PrivateSlotGrants
)

func slotBudgetLayoutForVersion(version string) slotBudgetLayout {
	return providerVersions.SlotBudgetLayout(version)
}
