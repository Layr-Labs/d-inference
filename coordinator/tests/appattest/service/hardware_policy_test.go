package service_test

import (
	"strings"
	"testing"

	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAppAttestHardwareClaimsMustBeSignedAndMatchRegistration(t *testing.T) {
	h := protocol.Hardware{MachineModel: "Mac17,6", ChipName: "Apple M5 Max", MemoryGB: 128, CPUCores: protocol.CPUCores{Total: 18, Performance: 12, Efficiency: 6}, GPUCores: 40}
	s := &protocol.AppAttestStatus{MachineModel: h.MachineModel, Chip: h.ChipName, MemoryGB: "128", CPUTotal: "18", CPUPerformance: "12", CPUEfficiency: "6", GPUCores: "40"}
	if known, matched := eligibility.HardwareComparison(s, h); !known || !matched {
		t.Fatal("matching signed claims rejected")
	}
	h.MemoryGB = 1024
	if known, matched := eligibility.HardwareComparison(s, h); !known || matched {
		t.Fatal("registration memory inflation not detected")
	}
	s.GPUCores = ""
	if known, _ := eligibility.HardwareComparison(s, h); known {
		t.Fatal("partial hardware treated as complete")
	}
	x := &inboxFixture{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.offer(protocol.AppAttestShadowPayload{Status: &protocol.AppAttestStatus{MemoryGB: strings.Repeat("x", 129)}})
	if len(x.in) != 0 || x.dropped.Load() != 1 {
		t.Fatal("new fields bypassed size bound")
	}
}
