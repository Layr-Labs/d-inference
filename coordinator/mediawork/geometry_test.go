package mediawork

import (
	"os"
	"strings"
	"testing"
)

func testProfile(t *testing.T) *Profile {
	t.Helper()
	data, err := os.ReadFile("testdata/mimo-config.json")
	if err != nil {
		t.Fatal(err)
	}
	p := FromConfig(data)
	if p == nil {
		t.Fatal("valid native profile rejected")
	}
	return p
}

func TestNativeMediaGeometryMatchesSDKVectors(t *testing.T) {
	p := testProfile(t)
	for _, c := range []struct{ w, h, tokens int }{{1280, 851, 1082}, {640, 461, 282}, {1920, 1080, 2042}, {3840, 2160, 8162}, {2048, 4096, 8194}, {8192, 1024, 8194}} {
		got, ok := p.ImageTokens(c.h, c.w)
		if !ok || got != c.tokens {
			t.Errorf("%dx%d: %d,%v want%d", c.w, c.h, got, ok, c.tokens)
		}
	}
	for _, c := range []struct {
		w, h, frames int
		seconds      float64
		tokens       int
	}{{1280, 720, 150, 5.056, 3550}, {1490, 534, 325, 10.833, 4032}} {
		got, ok := p.VideoTokens(c.h, c.w, c.frames, c.seconds)
		if !ok || got != c.tokens {
			t.Errorf("video%dx%d: %d,%v want%d", c.w, c.h, got, ok, c.tokens)
		}
	}
	if _, ok := p.ImageTokens(0, 100); ok {
		t.Fatal("zero geometry accepted")
	}
	if _, ok := p.ImageTokens(32, 10000); ok {
		t.Fatal("unsupported aspect accepted")
	}
	if _, ok := p.VideoTokens(100, 100, 1, 1); ok {
		t.Fatal("single-frame video accepted")
	}
	if _, ok := (*Profile)(nil).ImageTokens(100, 100); ok {
		t.Fatal("nil profile accepted")
	}
}

func TestNativeMediaProfileIsConfigurationBound(t *testing.T) {
	data, err := os.ReadFile("testdata/mimo-config.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, change := range [][2]string{{`"mimo_v2"`, `"qwen"`}, {`"temporal_compression_ratio": 1`, `"temporal_compression_ratio": 2`}, {`"use_video_timestamps": true`, `"use_video_timestamps": false`}, {`"spatial_merge_size":2`, `"spatial_merge_size":3`}, {`"fps": 1`, `"fps": -1`}} {
		if FromConfig([]byte(strings.Replace(string(data), change[0], change[1], 1))) != nil {
			t.Errorf("accepted unsupported%s", change[0])
		}
	}
	if FromConfig([]byte(`{"model_type":"mimo_v2"}`)) != nil {
		t.Fatal("missing processor accepted")
	}
}
