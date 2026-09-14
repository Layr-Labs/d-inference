package catalog

import (
	"strconv"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// retiredBuildsAfterUpsert keeps the alias lineage: rotated-out members are
// retained (bounded), re-promoted members leave the list.
func TestRetiredBuildsAfterUpsert(t *testing.T) {
	// No prior alias → no lineage.
	if got := retiredBuildsAfterUpsert(nil, "b2", ""); got != nil {
		t.Fatalf("no prior should yield nil, got %v", got)
	}
	// Rotation: desired b1→b2 (previous b1) retires nothing (b1 still a member);
	// then b2→b3 with previous cleared retires both b2 and b1.
	step1 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b1"}, "b2", "b1")
	if len(step1) != 0 {
		t.Fatalf("members must not be retired, got %v", step1)
	}
	step2 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b2", PreviousBuild: "b1"}, "b3", "")
	if len(step2) != 2 || step2[0] != "b2" || step2[1] != "b1" {
		t.Fatalf("rotated-out members should be retired, got %v", step2)
	}
	// Re-promotion: b1 comes back as desired → leaves the lineage.
	step3 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b3", RetiredBuilds: []string{"b2", "b1"}}, "b1", "")
	if len(step3) != 2 || step3[0] != "b2" || step3[1] != "b3" {
		t.Fatalf("re-promoted build must leave lineage and old desired must join, got %v", step3)
	}
	// Bound: the oldest entries are dropped first.
	var many []string
	for i := 0; i < maxRetiredBuilds+4; i++ {
		many = append(many, "old-"+strconv.Itoa(i))
	}
	bounded := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "bX", RetiredBuilds: many}, "bY", "")
	if len(bounded) != maxRetiredBuilds {
		t.Fatalf("lineage should be bounded to %d, got %d", maxRetiredBuilds, len(bounded))
	}
	if bounded[0] == "old-0" {
		t.Fatal("oldest entry should be dropped first")
	}
}

func TestStandardAliasCoversEveryBuildState(t *testing.T) {
	for name, alias := range map[string]store.ModelAlias{
		"desired":  {Active: true, DesiredBuild: "source"},
		"previous": {Active: true, PreviousBuild: "source"},
		"retired":  {Active: true, RetiredBuilds: []string{"source"}},
	} {
		t.Run(name, func(t *testing.T) {
			if !standardAliasCoversBuild(alias, "source") {
				t.Fatalf("%s build was not covered: %+v", name, alias)
			}
		})
	}
}
