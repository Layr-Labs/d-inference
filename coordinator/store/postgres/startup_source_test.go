package postgres

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// Read the actual unconditional startup path, including every schema domain.
// The separately gated backfills are deliberately excluded: their guarded SQL
// must not be mistaken for an unconditional boot-time aggregation or dedupe.
func startupMigrationSource(t *testing.T) []byte {
	t.Helper()
	paths := []string{"store.go", "schema.go", "startup.go", "earnings_index.go"}
	schemaPaths, err := filepath.Glob("schema/*.go")
	if err != nil || len(schemaPaths) == 0 {
		t.Fatalf("locate startup schema sources: %v (%d files)", err, len(schemaPaths))
	}
	paths = append(paths, schemaPaths...)
	var source bytes.Buffer
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read startup source %s: %v", path, err)
		}
		source.Write(data)
		source.WriteByte('\n')
	}
	return source.Bytes()
}
