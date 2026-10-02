package registry

import (
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotProjectionPreservesEveryHardRoutingTrait(t *testing.T) {
	traits := RequestTraits{TargetProviderID: "private-machine", ToolChoiceName: "private-tool", ParallelToolCalls: true, AvoidVersion: "soft-retry-hint"}
	// TargetProviderID belongs only to exclusive self-route, which is excluded
	// from public Autopilot demand before this projection. Keep machine ids out.
	omitted := map[string]bool{"TargetProviderID": true, "ToolChoiceName": true, "ParallelToolCalls": true, "AvoidVersion": true}
	value := reflect.ValueOf(&traits).Elem()
	requirements := reflect.TypeOf(autopilot.Requirements{})
	for i := 0; i < value.NumField(); i++ {
		name := value.Type().Field(i).Name
		if omitted[name] {
			continue
		}
		if _, ok := requirements.FieldByName(name); !ok {
			t.Fatalf("new request trait %s needs an explicit projected/omitted classification", name)
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
	roundtrip := reflect.ValueOf(requestTraitsForAutopilot(projected))
	for i := 0; i < value.NumField(); i++ {
		name := value.Type().Field(i).Name
		if omitted[name] {
			if !roundtrip.Field(i).IsZero() {
				t.Fatalf("non-demand data %s retained", name)
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
		makeIneligible func(*Provider)
	}{
		{"vision", autopilot.Requirements{RequiresVision: true}, func(p *Provider) { p.Models[0].IsVision = false }},
		{"tools template", autopilot.Requirements{HasTools: true}, func(p *Provider) { broken := false; p.Models[0].TemplateRenderOK = &broken }},
		{"none template", autopilot.Requirements{HasTools: true, ToolChoiceMode: "none"}, func(p *Provider) { broken := false; p.Models[0].TemplateRenderOK = &broken }},
		{"sampler", autopilot.Requirements{HasTools: true, RequiresToolConstraint: true}, func(p *Provider) { p.ToolConstraintProtocol = 0 }},
		{"native media", autopilot.Requirements{RequiresVision: true, HasTools: true, RequiresNativeMediaTools: true}, func(p *Provider) { p.Models[0].NativeMediaTools = false }},
		{"prefix wire floor", autopilot.Requirements{MinPrefixCacheProtocol: 1}, func(p *Provider) { p.PrefixCacheProtocol = 0 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			for _, id := range []string{"eligible", "ineligible"} {
				p := autopilotControllerProvider(t, r, id, now, autopilotTestTarget)
				p.mu.Lock()
				p.Version = "0.9.10"
				p.PrefixCacheProtocol = 1
				p.ToolConstraintProtocol = ToolConstraintProtocolV1
				p.ToolConstraintModels = map[string]struct{}{autopilotTestTarget: {}}
				p.Models[0].IsVision = true
				p.Models[0].NativeMediaTools = true
				if id == "ineligible" {
					tc.makeIneligible(p)
				}
				p.syncModelIndexLocked()
				p.mu.Unlock()
			}
			sample := autopilot.DemandSample{Requirements: tc.requirements, Model: autopilotTestTarget,
				ReceivedAt: now.Add(-time.Second), PromptTokens: 100, RequestedMaxTokens: 64}
			c.demand.Record(sample, now, c.config.DemandWindow)
			fleet := r.autopilotFleetSnapshot(c, now)
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
