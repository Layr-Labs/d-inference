package response_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestChatCompletionMetadataOmitsDeviceSerial(t *testing.T) {
	t.Parallel()
	se := true
	info := production.CommittedProviderInfo{
		ProviderID:    "prov-1",
		Attested:      true,
		TrustLevel:    registry.TrustHardware,
		Encrypted:     true,
		Chip:          "Apple M4 Max",
		MachineModel:  "Mac16,7",
		SecureEnclave: &se,
		MDAVerified:   true,
		SEPublicKey:   "se-pub",
	}
	provider := &registry.Provider{
		ID:        "prov-1",
		Hardware:  protocol.Hardware{ChipName: "Apple M4 Max", MachineModel: "Mac16,7"},
		PublicKey: "x25519",
		Attested:  true,
		AttestationResult: &attestation.VerificationResult{
			PublicKey:              "se-pub",
			SerialNumber:           "SECRET-SERIAL",
			SecureEnclaveAvailable: true,
		},
		TrustLevel:  registry.TrustHardware,
		MDAVerified: true,
		Location: &store.ProviderLocation{
			City:        "Austin",
			Region:      "Texas",
			RegionCode:  "TX",
			Country:     "United States",
			CountryCode: "US",
			Latitude:    30.2672,
			Longitude:   -97.7431,
			Timezone:    "America/Chicago",
			Source:      "ip-api-pro",
		},
	}
	collected := production.CollectCommittedProviderInfo(provider)
	if collected.SEPublicKey != "se-pub" {
		t.Fatalf("se public key = %q", collected.SEPublicKey)
	}
	if collected.Location == nil || collected.Location.Region != "Texas" || collected.Location.CountryCode != "US" {
		t.Fatalf("location = %+v", collected.Location)
	}
	info.Location = collected.Location
	start := time.Now()
	pr := &registry.PendingRequest{RequestID: "job-1", MetadataDetails: true,
		Timing: &registry.RequestTiming{ReceivedAt: start, ParsedAt: start.Add(10 * time.Microsecond)}}
	production.SnapshotChatCompletionMetadata(pr, info)
	raw := pr.ResponseMetadata
	if len(raw) == 0 {
		t.Fatal("metadata snapshot missing")
	}
	if strings.Contains(string(raw), "SECRET-SERIAL") || strings.Contains(string(raw), "serial") {
		t.Fatalf("metadata leaked a device serial: %s", raw)
	}
	if strings.Contains(string(raw), "30.2672") || strings.Contains(string(raw), "-97.7431") || strings.Contains(string(raw), "ip-api") || strings.Contains(string(raw), "latitude") || strings.Contains(string(raw), `"city"`) || strings.Contains(string(raw), "Austin") {
		t.Fatalf("metadata leaked city, precise geo, or lookup source: %s", raw)
	}
	var decoded types.ChatCompletionMetadata
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ProviderID != "prov-1" || !decoded.ProviderAttested || decoded.ProviderTrustLevel != "hardware" {
		t.Fatalf("unexpected metadata: %+v", decoded)
	}
	if decoded.JobID != "job-1" || decoded.Timing == nil || decoded.Timing.ParseUs != 10 {
		t.Fatalf("job/timing missing: %+v", decoded)
	}
	if decoded.Location == nil || decoded.Location.Region != "Texas" || decoded.Location.Timezone != "America/Chicago" {
		t.Fatalf("location missing from body: %+v", decoded.Location)
	}
}
