package hardwareadmission

import "testing"

func TestEvaluateThresholdBoundaries(t *testing.T) {
	policy := Policy{
		Mode: ModeEnforce, CatalogVersion: CatalogVersion,
		MinMemoryGB: 32, MinMemoryBandwidthGBs: 200, MinFP16MilliTFLOPS: 9_175,
	}
	input := Input{
		MachineModel: "MacBookPro18,3", ChipName: "Apple M1 Pro",
		ChipFamily: "M1", ChipTier: "Pro", MemoryGB: 32, GPUCores: 14,
	}
	got := Evaluate(policy, input)
	if !got.Allowed || !got.MeetsThresholds {
		t.Fatalf("boundary hardware should pass: %+v", got)
	}
	if got.Observed.MemoryBandwidthGBs != 200 {
		t.Fatalf("bandwidth = %d, want 200", got.Observed.MemoryBandwidthGBs)
	}
	if got.Observed.FP16MilliTFLOPS != 9_175 {
		t.Fatalf("FP16 milli-TFLOPS = %d, want 9175", got.Observed.FP16MilliTFLOPS)
	}
}

func TestEvaluateEnforceRejectsAllFailedDimensions(t *testing.T) {
	policy := Policy{
		Mode: ModeEnforce, CatalogVersion: CatalogVersion,
		MinMemoryGB: 32, MinMemoryBandwidthGBs: 200, MinFP16MilliTFLOPS: 20_000,
	}
	got := Evaluate(policy, Input{
		MachineModel: "MacBookAir10,1", ChipName: "Apple M1",
		ChipFamily: "M1", ChipTier: "Base", MemoryGB: 16, GPUCores: 8,
	})
	if got.Allowed || got.MeetsThresholds {
		t.Fatalf("low-spec hardware unexpectedly passed: %+v", got)
	}
	if len(got.FailedChecks) != 3 {
		t.Fatalf("failed checks = %d, want 3: %+v", len(got.FailedChecks), got.FailedChecks)
	}
}

func TestEvaluateShadowRecordsFailureButAllows(t *testing.T) {
	policy := Policy{Mode: ModeShadow, CatalogVersion: CatalogVersion, MinMemoryGB: 32}
	got := Evaluate(policy, Input{MemoryGB: 16})
	if !got.Allowed || got.MeetsThresholds {
		t.Fatalf("shadow decision = %+v, want allowed would-reject", got)
	}
}

func TestEvaluateUnknownHardwareFailsDerivedThresholdOnly(t *testing.T) {
	policy := Policy{
		Mode: ModeEnforce, CatalogVersion: CatalogVersion,
		MinMemoryGB: 16, MinMemoryBandwidthGBs: 100,
	}
	got := Evaluate(policy, Input{MemoryGB: 64, ChipFamily: "M9", ChipTier: "Max", GPUCores: 80})
	if got.Allowed {
		t.Fatal("unknown chip passed a derived bandwidth threshold")
	}
	if len(got.FailedChecks) != 1 || got.FailedChecks[0].Code != "hardware_not_catalogued" {
		t.Fatalf("failed checks = %+v", got.FailedChecks)
	}
}

func TestPolicyValidate(t *testing.T) {
	if err := (Policy{Mode: ModeEnforce, CatalogVersion: CatalogVersion, MinMemoryGB: 32}).Validate(); err != nil {
		t.Fatalf("valid policy rejected: %v", err)
	}
	if err := (Policy{Mode: "maybe", CatalogVersion: CatalogVersion}).Validate(); err == nil {
		t.Fatal("invalid mode accepted")
	}
	if err := (Policy{Mode: ModeEnforce, CatalogVersion: "unknown"}).Validate(); err == nil {
		t.Fatal("unsupported catalog accepted")
	}
}

func TestEnforceActivationRequiresCapacityThreshold(t *testing.T) {
	if err := (Policy{
		Mode: ModeEnforce, CatalogVersion: CatalogVersion,
	}).ValidateForActivation(); err == nil {
		t.Fatal("zero-threshold enforce policy was accepted")
	}
	if err := (Policy{
		Mode: ModeEnforce, MinMemoryGB: 32, CatalogVersion: CatalogVersion,
	}).ValidateForActivation(); err != nil {
		t.Fatalf("positive-threshold enforce policy rejected: %v", err)
	}
}
