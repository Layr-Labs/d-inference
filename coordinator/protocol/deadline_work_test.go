package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestCalibratedCapacityWireSymmetryAndClone(t *testing.T) {
	data, err := os.ReadFile("testdata/calibrated_capacity_wire_fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	var capacity BackendCapacity
	if err = json.Unmarshal(data, &capacity); err != nil {
		t.Fatal(err)
	}
	slot := capacity.Slots[0]
	if slot.DeadlineWork == nil || slot.DeadlineWork.Version != 1 || !slot.DeadlineWork.Known || slot.DeadlineWork.Epoch != slot.PerformanceMeasurements.Epoch || slot.DeadlineWork.PrefillTokens != 8192 || slot.DeadlineWork.DecodeTokens != 512 || slot.DeadlineWork.RequestCount != 2 || slot.DeadlineWork.ContextTokensMax != 8704 || slot.DeadlineWork.ServiceFraction != .5 {
		t.Fatalf("work envelope lost: %+v", slot.DeadlineWork)
	}
	mtp := slot.PerformanceProfile.MTP
	if mtp == nil || !mtp.Enabled || mtp.FixedDraftTokens == nil || *mtp.FixedDraftTokens != 0 || mtp.VerificationMode != "automatic" {
		t.Fatalf("MTP identity lost: %+v", mtp)
	}
	deadline := slot.DeadlineProfile
	if deadline == nil || deadline.ID != "test-reviewed-deadline" || deadline.ConfiguredContextTokens != 262144 ||
		deadline.MinimumWholeMacQuiescenceMS == nil || *deadline.MinimumWholeMacQuiescenceMS != 20000 ||
		deadline.MinimumNominalStabilityMS == nil || *deadline.MinimumNominalStabilityMS != 5000 || deadline.PowerMode != "automatic" ||
		deadline.EffectiveMaxConcurrency != 16 || deadline.PrefillChunkSize != 512 || deadline.MaxConcurrentPartialPrefills != 1 ||
		deadline.MixedPrefillTokenCap == nil || *deadline.MixedPrefillTokenCap != 256 ||
		deadline.SoloPrefillStripeTokens == nil || *deadline.SoloPrefillStripeTokens != 4096 || !deadline.MTP.Equal(mtp) {
		t.Fatalf("independent deadline identity lost: %+v", deadline)
	}
	encoded, err := json.Marshal(capacity)
	if err != nil {
		t.Fatal(err)
	}
	var decoded BackendCapacity
	if err = json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(capacity, decoded) {
		t.Fatal("capacity changed during roundtrip")
	}
	cloned := mtp.Clone()
	*cloned.FixedDraftTokens = 1
	if *mtp.FixedDraftTokens != 0 || cloned.Equal(mtp) {
		t.Fatal("MTP identity clone shared mutable configuration")
	}
	clonedDeadline := deadline.Clone()
	*clonedDeadline.MinimumWholeMacQuiescenceMS = 0
	*clonedDeadline.MinimumNominalStabilityMS = 10000
	*clonedDeadline.MixedPrefillTokenCap = 1
	*clonedDeadline.SoloPrefillStripeTokens = 1
	*clonedDeadline.MTP.FixedDraftTokens = 1
	if *deadline.MinimumWholeMacQuiescenceMS != 20000 || *deadline.MinimumNominalStabilityMS != 5000 || *deadline.MixedPrefillTokenCap != 256 || *deadline.SoloPrefillStripeTokens != 4096 || *deadline.MTP.FixedDraftTokens != 0 {
		t.Fatal("deadline identity clone shared mutable policy")
	}
	clonedWork := slot.DeadlineWork.Clone()
	clonedWork.PrefillTokens = 1
	if slot.DeadlineWork.PrefillTokens != 8192 {
		t.Fatal("work clone changed accepted snapshot")
	}
	legacy, err := json.Marshal(BackendSlotCapacity{Model: "legacy"})
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err = json.Unmarshal(legacy, &raw); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"deadline_work", "deadline_profile"} {
		if _, ok := raw[field]; ok {
			t.Fatalf("legacy omission changed for %s", field)
		}
	}
}
