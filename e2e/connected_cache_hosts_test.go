package e2e

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

// Readiness is measured before each next request. Post-work cleanup is checked
// separately by Stop and cannot relabel a completed hot request as incorrect.
func waitConnectedHostEntry(ctx context.Context, suite *testbed.Suite, model string, in connectedCacheInput) ([]testbed.HostObservation, error) {
	wait, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	entryKind := "measured"
	if in.CorrectnessOnly {
		entryKind = "correctness"
	}
	var latest []testbed.HostObservation
	for {
		latest = nil
		ready := true
		for index, p := range suite.Providers {
			observation, err := p.ObserveHost(wait)
			if err != nil {
				return latest, err
			}
			latest = append(latest, observation)
			if connectedHostEntryReady(observation, in.Providers[index], in.CorrectnessOnly) != nil {
				ready = false
			}
		}
		if !connectedSlotsQuiescent(connectedSlots(suite, model), len(suite.Providers), model) {
			ready = false
		}
		if ready {
			return latest, nil
		}
		select {
		case <-wait.Done():
			return latest, fmt.Errorf("next %s entry not ready: %w", entryKind, wait.Err())
		case <-time.After(time.Second):
		}
	}
}

// Targets may move paths between hosts, but cannot change the selected runtime,
// target weights, assistant weights or immutable catalog input.
func validateConnectedTargetBindings(in connectedCacheInput) error {
	if in.Providers == nil {
		return nil
	}
	if err := testbed.ValidateProviderTargets(in.Providers, 2); err != nil {
		return err
	}
	selectedRuntime := in.Providers[0].RuntimeFiles
	for _, target := range in.Providers {
		if len(target.RuntimeFiles) != len(selectedRuntime) {
			return fmt.Errorf("host runtime manifest differs from selected runtime")
		}
		for name, expected := range selectedRuntime {
			if actual, ok := target.RuntimeFiles[name]; !ok || actual != expected {
				return fmt.Errorf("host runtime file differs from selected runtime: %s", name)
			}
		}
		if target.RuntimeFiles["darkbloom"].SHA256 != in.ProviderSHA256 || target.RuntimeFiles["mlx.metallib"].SHA256 != in.MetallibSHA256 {
			return fmt.Errorf("host runtime differs from selected connected runtime")
		}
		if (target.AssistantPath == "") != (in.AssistantPath == "") {
			return fmt.Errorf("host assistant selection differs")
		}
		if len(target.Models) != len(in.Catalog) {
			return fmt.Errorf("host model inputs differ from exact catalog")
		}
		for _, model := range target.Models {
			found := false
			for _, catalog := range in.Catalog {
				if model.ID != catalog.Entry.ID {
					continue
				}
				found = true
				if catalog.Manifest.ModelID != model.ID || len(model.Files) != len(catalog.Manifest.Files) {
					return fmt.Errorf("host model manifest differs from catalog")
				}
				for _, file := range catalog.Manifest.Files {
					actual, ok := model.Files[file.Path]
					if !ok || actual.SHA256 != file.SHA256 || actual.Bytes != file.SizeBytes {
						return fmt.Errorf("host model file differs from selected catalog")
					}
				}
				if model.Snapshot == target.AssistantPath && model.ID == in.Artifact.ModelID {
					return fmt.Errorf("assistant cannot substitute target model")
				}
			}
			if !found {
				return fmt.Errorf("host model not in selected catalog")
			}
		}
	}
	return nil
}
