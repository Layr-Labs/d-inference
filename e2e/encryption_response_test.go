package e2e

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// This test oracle is specific to the unchanged "2+2, just the number"
// fixture. Surrounding JSON-compatible whitespace is formatting, not encrypted
// data. No response bytes are rewritten and no production parser uses this.
func expectedDecryptedArithmeticAnswer(content string) bool {
	return utf8.ValidString(content) && strings.Trim(content, " \t\r\n") == "4"
}

func TestDecryptedArithmeticPlaintext(t *testing.T) {
	for _, test := range []struct {
		name, content string
		want          bool
	}{
		{"bare", "4", true},
		{"native-leading-newlines", "\n\n4", true},
		{"trailing-newline", "4\n", true},
		{"ascii-whitespace", " \t4\r\n", true},
		{"empty", "", false},
		{"whitespace-only", "\n\n", false},
		{"wrong-answer", "5", false},
		{"printable-base64", "NA==", false},
		{"embedded-control", "4\x00", false},
		{"invalid-utf8", string([]byte{0xff, '4'}), false},
		{"unexpected-invisible", "4\u200b", false},
		{"reasoning-leak", "<think>2+2</think>4", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := expectedDecryptedArithmeticAnswer(test.content); got != test.want {
				t.Fatalf("plaintext validation = %v, want %v for %q", got, test.want, test.content)
			}
		})
	}
}
