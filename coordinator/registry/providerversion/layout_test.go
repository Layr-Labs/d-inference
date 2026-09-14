package providerversion

import "testing"

func TestSlotBudgetLayoutForVersionHandlesReleaseSuffixes(t *testing.T) {
	var policy Policy
	cases := []struct {
		version string
		want    SlotBudgetLayout
	}{
		{version: "0.7.4", want: SharedSlotHeadroom},
		{version: "0.7.5", want: PrivateSlotGrants},
		{version: "0.7.5-dev.1", want: PrivateSlotGrants},
		{version: "v0.7.5-rc1", want: PrivateSlotGrants},
		{version: "0.7.5+build.9", want: PrivateSlotGrants},
	}
	for _, tc := range cases {
		t.Run(tc.version, func(t *testing.T) {
			if got := policy.SlotBudgetLayout(tc.version); got != tc.want {
				t.Fatalf("slotBudgetLayoutForVersion(%q) = %v, want %v", tc.version, got, tc.want)
			}
		})
	}
}
