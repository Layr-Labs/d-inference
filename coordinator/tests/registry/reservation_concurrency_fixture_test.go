package registry_test

import "testing"

func forEachCommitMode(t *testing.T, body func(t *testing.T, mode string)) {
	t.Helper()
	for _, mode := range []string{"shared", "global"} {
		t.Run(mode, func(t *testing.T) { body(t, mode) })
	}
}
