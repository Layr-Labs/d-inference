package api

import (
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequiredProviderCapabilitiesMemoryAndCatalogRoundTrip(t *testing.T) {
	st := store.NewMemory(store.Config{})
	entry := &store.ModelRegistryEntry{
		ID: registry.Qwen38NAXModelID, DisplayName: "Qwen3.8 27B",
		Quantization: "4bit", MaxContextLength: 131072,
		MaxOutputLength: 8192, MinRAMGB: 64, Status: "active",
		RequiredProviderCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
	}
	version := &store.ModelVersion{
		ModelID: entry.ID, Version: "v1", R2Prefix: "models/qwen38/v1",
		AggregateSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Status:          "ready",
	}
	if err := st.SetModelVersion(entry, version, nil); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(entry.ID, version.Version); err != nil {
		t.Fatal(err)
	}
	record, err := st.GetModelRegistryRecord(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(record.RequiredProviderCapabilities, entry.RequiredProviderCapabilities) {
		t.Fatalf("store round trip = %v, want %v",
			record.RequiredProviderCapabilities, entry.RequiredProviderCapabilities)
	}

	catalog := catalogModelFromRegistryRecord(record)
	if got := catalog["required_provider_capabilities"]; !reflect.DeepEqual(got, entry.RequiredProviderCapabilities) {
		t.Fatalf("catalog API field = %#v, want %v", got, entry.RequiredProviderCapabilities)
	}
	supported := supportedModelFromRegistryRecord(record)
	if !reflect.DeepEqual(supported.RequiredProviderCapabilities, entry.RequiredProviderCapabilities) {
		t.Fatalf("supported model field = %v", supported.RequiredProviderCapabilities)
	}

	// Returned slices are detached from memory storage.
	record.RequiredProviderCapabilities[0] = "mutated"
	again, err := st.GetModelRegistryRecord(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(again.RequiredProviderCapabilities, entry.RequiredProviderCapabilities) {
		t.Fatalf("memory clone leaked caller mutation: %v", again.RequiredProviderCapabilities)
	}
}

func TestValidateRequiredProviderCapabilities(t *testing.T) {
	valid := []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}
	if err := validateRequiredProviderCapabilities(registry.Qwen38NAXModelID, valid); err != nil {
		t.Fatalf("valid protected requirements rejected: %v", err)
	}
	for name, capabilities := range map[string][]string{
		"missing":    {registry.ProviderCapabilityAppleM5},
		"empty":      {""},
		"whitespace": {" apple_m5", registry.ProviderCapabilityMLXNAX},
		"duplicate":  {registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityAppleM5},
		"unknown":    {registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX, "future"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateRequiredProviderCapabilities(registry.Qwen38NAXModelID, capabilities); err == nil {
				t.Fatalf("accepted invalid requirements %v", capabilities)
			}
		})
	}
	if err := validateRequiredProviderCapabilities("unrelated-model", nil); err != nil {
		t.Fatalf("empty requirements broke existing model: %v", err)
	}
}
