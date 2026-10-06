package device_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/api/access/devicecode"
)

func TestGenerateUserCodeFormat(t *testing.T) {
	for range 20 {
		code, err := devicecode.Generate()
		if err != nil {
			t.Fatalf("generateUserCode: %v", err)
		}
		if len(code) != 9 || code[4] != '-' {
			t.Errorf("code = %q, want XXXX-XXXX format", code)
		}
		for _, c := range strings.ReplaceAll(code, "-", "") {
			if c == '0' || c == 'O' || c == '1' || c == 'I' || c == 'L' {
				t.Errorf("code %q contains ambiguous char %q", code, c)
			}
		}
	}
}

func TestSha256HashDeterministic(t *testing.T) {
	h1 := devicecode.Hash("test-input")
	h2 := devicecode.Hash("test-input")
	if h1 != h2 {
		t.Error("sha256Hash should be deterministic")
	}
	if len(h1) != 64 {
		t.Errorf("hash length = %d, want 64", len(h1))
	}
	h3 := devicecode.Hash("different")
	if h1 == h3 {
		t.Error("different inputs should produce different hashes")
	}
}
