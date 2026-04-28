package pseudonym

import "testing"

func TestAliasDeterministic(t *testing.T) {
	gen, err := NewGenerator("secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}

	first := gen.Alias("account", "acct-123")
	second := gen.Alias("account", "acct-123")
	if first != second {
		t.Fatalf("alias mismatch: %q != %q", first, second)
	}
}

func TestAliasChangesAcrossKinds(t *testing.T) {
	gen, err := NewGenerator("secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}

	accountAlias := gen.Alias("account", "shared-id")
	nodeAlias := gen.Alias("node", "shared-id")
	if accountAlias == nodeAlias {
		t.Fatalf("expected aliases for different kinds to differ, got %q", accountAlias)
	}
}
