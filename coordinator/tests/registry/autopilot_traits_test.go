package registry_test

import (
	"reflect"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotProjectionPreservesEveryHardRoutingTrait(t *testing.T) {
	traits := production.RequestTraits{ToolChoiceName: "private-tool", ParallelToolCalls: true, AvoidVersion: "soft-retry-hint"}
	soft := map[string]bool{"ToolChoiceName": true, "ParallelToolCalls": true, "AvoidVersion": true}
	value := reflect.ValueOf(&traits).Elem()
	requirements := reflect.TypeOf(autopilot.Requirements{})
	for i := 0; i < value.NumField(); i++ {
		name := value.Type().Field(i).Name
		if soft[name] {
			continue
		}
		if _, ok := requirements.FieldByName(name); !ok {
			t.Fatalf("new request trait %s needs an explicit hard/soft classification", name)
		}
		switch value.Field(i).Kind() {
		case reflect.Bool:
			value.Field(i).SetBool(true)
		case reflect.String:
			value.Field(i).SetString("none")
		case reflect.Int:
			value.Field(i).SetInt(1)
		default:
			t.Fatalf("new hard trait %s needs a regression value", name)
		}
	}
	projected := traits.AutopilotRequirements(true)
	if !projected.RequiresVision {
		t.Fatal("vision requirement lost")
	}
	roundtrip := reflect.ValueOf(production.RequestTraitsForAutopilot(projected))
	for i := 0; i < value.NumField(); i++ {
		name := value.Type().Field(i).Name
		if soft[name] {
			if !roundtrip.Field(i).IsZero() {
				t.Fatalf("non-eligibility data %s retained", name)
			}
		} else if !reflect.DeepEqual(value.Field(i).Interface(), roundtrip.Field(i).Interface()) {
			t.Fatalf("hard trait %s was lost", name)
		}
	}
}

func TestAutopilotCapacityUsesAllHardEligibilityGates(t *testing.T) {
	for _, tc := range []struct {
		name           string
		requirements   autopilot.Requirements
		makeIneligible func(*production.Provider)
	}{
		{"vision", autopilot.Requirements{RequiresVision: true}, func(p *production.Provider) { p.Models[0].IsVision = false }},
		{"tools template", autopilot.Requirements{HasTools: true}, func(p *production.Provider) { broken := false; p.Models[0].TemplateRenderOK = &broken }},
		{"none template", autopilot.Requirements{HasTools: true, ToolChoiceMode: "none"}, func(p *production.Provider) { broken := false; p.Models[0].TemplateRenderOK = &broken }},
		{"sampler", autopilot.Requirements{HasTools: true, RequiresToolConstraint: true}, func(p *production.Provider) { p.ToolConstraintProtocol = 0 }},
		{"native media", autopilot.Requirements{RequiresVision: true, HasTools: true, RequiresNativeMediaTools: true}, func(p *production.Provider) { p.Models[0].NativeMediaTools = false }},
		{"prefix wire floor", autopilot.Requirements{MinPrefixCacheProtocol: 1}, func(p *production.Provider) { p.PrefixCacheProtocol = 0 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			for _, id := range []string{"eligible", "ineligible"} {
				p := autopilotControllerProvider(t, r, id, now, autopilotTestTarget)
				p.Mu().Lock()
				p.Version = "0.9.10"
				p.PrefixCacheProtocol = 1
				p.ToolConstraintProtocol = production.ToolConstraintProtocolV1
				p.ToolConstraintModels = map[string]struct{}{autopilotTestTarget: {}}
				p.Models[0].IsVision = true
				p.Models[0].NativeMediaTools = true
				if id == "ineligible" {
					tc.makeIneligible(p)
				}
				p.Mu().Unlock()
			}
			sample := autopilot.DemandSample{Requirements: tc.requirements, Model: autopilotTestTarget,
				ReceivedAt: now.Add(-time.Second), PromptTokens: 100, RequestedMaxTokens: 64}
			r.demand.Record(sample, now, r.cfg.DemandWindow)
			fleet := c.Fleet(now)
			key := autopilot.ShapeKey(sample)
			for _, node := range fleet.Nodes {
				_, fits := node.Fits[key]
				if fits != (node.ID == "eligible") {
					t.Fatalf("provider %s credited=%v", node.ID, fits)
				}
			}
		})
	}
}
