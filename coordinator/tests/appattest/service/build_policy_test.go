package service_test

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
)

func TestAppAttestBuildMeasurementUsesQualifiedExactArtifactPair(t *testing.T) {
	binary := strings.Repeat("a", 64)
	digest := bytes.Repeat([]byte{0xbb}, 32)
	algorithm := uint8(2)
	meta := &appattest.Key{CodeDirectoryHash: digest, CodeDirectoryType: &algorithm}
	code := hex.EncodeToString(digest)
	for _, tc := range []struct {
		mapping        string
		known, matched bool
	}{
		{binary + ":" + code, true, true},
		{binary + ":" + strings.Repeat("c", 64), true, false},
		{strings.Repeat("d", 64) + ":" + code, false, false},
		{"", false, false},
		{binary, false, false},
		{binary + ":" + code[:40], false, false},
		{binary + ":" + code + ",broken", false, false},
		{binary + ":" + code + "," + binary + ":" + strings.Repeat("c", 64), false, false},
	} {
		known, matched := qualification.Code(tc.mapping, binary, hex.EncodeToString(meta.CodeDirectorySHA256()))
		if known != tc.known || matched != tc.matched {
			t.Fatalf("%q: %v %v", tc.mapping, known, matched)
		}
	}
	if known, _ := qualification.Code(binary+":"+code, binary, hex.EncodeToString((*appattest.Key)(nil).CodeDirectorySHA256())); known {
		t.Fatal("missing signed metadata qualified")
	}
	algorithm = 255
	if known, _ := qualification.Code(binary+":"+code, binary, hex.EncodeToString(meta.CodeDirectorySHA256())); known {
		t.Fatal("unknown algorithm qualified")
	}
	t.Setenv("EIGENINFERENCE_APP_ATTEST_QUALIFIED_CODE_HASHES", binary+":"+code)
	if service.ConfigFromEnvironment().QualifiedCodeHashes != binary+":"+code {
		t.Fatal("qualification mapping not configured")
	}
}
