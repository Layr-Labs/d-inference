package registry

import (
	"io"
	"log/slog"
	"reflect"
	"testing"
)

func TestCatalogDisplayNames(t *testing.T) {
	r := New(slog.New(slog.NewTextHandler(io.Discard, nil)))

	if got := r.CatalogDisplayNames(); len(got) != 0 {
		t.Fatalf("no catalog: got %v, want empty", got)
	}

	r.SetModelCatalog([]CatalogEntry{
		{ID: "EigenLabs/Qwen3.8-27B-4bit-mtp", DisplayName: "Qwen 3.8 27B"},
		{ID: "qwen3.6-35b-a3b-vl-mtp-mxfp8", DisplayName: "Qwen 3.6 35B A3B"},
		{ID: "gpt-oss-20b", DisplayName: "gpt-oss-20b"}, // name repeats the id: not a display name
		{ID: "local-experiment"}, // none published
	})
	want := map[string]string{
		"EigenLabs/Qwen3.8-27B-4bit-mtp": "Qwen 3.8 27B",
		"qwen3.6-35b-a3b-vl-mtp-mxfp8":   "Qwen 3.6 35B A3B",
	}
	got := r.CatalogDisplayNames()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("CatalogDisplayNames() = %v, want %v", got, want)
	}

	// The returned map is a copy: mutating it must not touch the catalog.
	got["gpt-oss-20b"] = "GPT-OSS 20B"
	if again := r.CatalogDisplayNames(); !reflect.DeepEqual(again, want) {
		t.Fatalf("catalog mutated through returned map: %v", again)
	}

	r.SetModelCatalog(nil)
	if got := r.CatalogDisplayNames(); len(got) != 0 {
		t.Fatalf("catalog disabled: got %v, want empty", got)
	}
}
