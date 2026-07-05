package env

import "testing"

const k = "EIGENINFERENCE_TEST_ENV_VAR"

func TestEnvOr(t *testing.T) {
	t.Setenv(k, "value")
	if got := EnvOr(k, "fallback"); got != "value" {
		t.Fatalf("EnvOr = %q, want value", got)
	}
	t.Setenv(k, "")
	if got := EnvOr(k, "fallback"); got != "fallback" {
		t.Fatalf("empty env should fall back, got %q", got)
	}
	if got := EnvOr("EIGENINFERENCE_TEST_UNSET", "fallback"); got != "fallback" {
		t.Fatalf("unset env should fall back, got %q", got)
	}
}

func TestFirstNonEmpty(t *testing.T) {
	if got := FirstNonEmpty("", "", "first", "second"); got != "first" {
		t.Fatalf("FirstNonEmpty = %q, want first", got)
	}
	if got := FirstNonEmpty("", ""); got != "" {
		t.Fatalf("all-empty should yield empty, got %q", got)
	}
	if got := FirstNonEmpty(); got != "" {
		t.Fatalf("no args should yield empty, got %q", got)
	}
}

func TestEnvFloat(t *testing.T) {
	t.Setenv(k, "3.5")
	if got := EnvFloat(k, 1.0); got != 3.5 {
		t.Fatalf("EnvFloat = %v, want 3.5", got)
	}
	t.Setenv(k, "not-a-float")
	if got := EnvFloat(k, 1.25); got != 1.25 {
		t.Fatalf("unparseable float should fall back, got %v", got)
	}
	if got := EnvFloat("EIGENINFERENCE_TEST_UNSET", 2.5); got != 2.5 {
		t.Fatalf("unset float should fall back, got %v", got)
	}
}

func TestEnvInt(t *testing.T) {
	t.Setenv(k, "42")
	if got := EnvInt(k, 7); got != 42 {
		t.Fatalf("EnvInt = %d, want 42", got)
	}
	t.Setenv(k, "3.5")
	if got := EnvInt(k, 7); got != 7 {
		t.Fatalf("non-integer should fall back, got %d", got)
	}
	if got := EnvInt("EIGENINFERENCE_TEST_UNSET", 9); got != 9 {
		t.Fatalf("unset int should fall back, got %d", got)
	}
}

func TestEnvBool(t *testing.T) {
	cases := []struct {
		set      bool
		val      string
		fallback bool
		want     bool
	}{
		{true, "true", false, true},
		{true, "false", true, false},
		{true, "1", false, true},
		{true, "0", true, false},
		{true, "  true  ", false, true}, // TrimSpace
		{true, "maybe", true, true},     // unparseable -> fallback
		{true, "", false, false},        // empty -> fallback
		{false, "", true, true},         // unset -> fallback
	}
	for _, tc := range cases {
		if tc.set {
			t.Setenv(k, tc.val)
		}
		key := k
		if !tc.set {
			key = "EIGENINFERENCE_TEST_UNSET_BOOL"
		}
		if got := EnvBool(key, tc.fallback); got != tc.want {
			t.Fatalf("EnvBool(%q, %v) = %v, want %v", tc.val, tc.fallback, got, tc.want)
		}
	}
}
