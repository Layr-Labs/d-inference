package main

import "testing"

func TestParseOperatorCommand(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name string
		args []string
		want operatorCommand
	}{
		{name: "default serve", want: operatorServe},
		{name: "explicit serve", args: []string{"serve"}, want: operatorServe},
		{name: "version", args: []string{"version"}, want: operatorVersion},
		{name: "check config", args: []string{"check-config"}, want: operatorConfigCheck},
		{name: "config check", args: []string{"config-check"}, want: operatorConfigCheck},
		{name: "rollback check", args: []string{"rollback-check"}, want: operatorRollbackCheck},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseOperatorCommand(test.args)
			if err != nil {
				t.Fatalf("parseOperatorCommand(%q): %v", test.args, err)
			}
			if got != test.want {
				t.Fatalf("parseOperatorCommand(%q) = %q, want %q", test.args, got, test.want)
			}
		})
	}
}

func TestParseOperatorCommandRejectsInjectionAndExtraArguments(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{
		{"rust;id"},
		{"serve", "--unexpected"},
		{"$(touch /tmp/injected)"},
		{""},
	} {
		if _, err := parseOperatorCommand(args); err == nil {
			t.Fatalf("parseOperatorCommand(%q) unexpectedly succeeded", args)
		}
	}
}
