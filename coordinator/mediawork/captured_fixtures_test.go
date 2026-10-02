package mediawork

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// Optional operator-owned fixtures stay outside the repository. The checked-in
// bounds come from the independently measured SDK geometry, with room only
// for timestamp/audio/wrapper tokens. No fixture bytes or derived IDs are logged.
func TestNativeMediaCapturedFixtures(t *testing.T) {
	root := os.Getenv("DARKBLOOM_TEST_MEDIA_FIXTURES")
	if root == "" {
		t.Skip("operator-owned media fixtures not configured")
	}
	p := testProfile(t)
	for _, tc := range []struct {
		name, kind string
		low, high  int
		video      bool
	}{
		{"input-image-url.jpg", "image/jpeg", 1082, 1082, false},
		{"input-image-base64.jpg", "image/jpeg", 282, 282, false},
		{"input-video-url.mp4", "video/mp4", 3550, 3604, true},
		{"input-video-base64.mov", "video/quicktime", 4020, 4045, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, err := os.ReadFile(filepath.Join(root, tc.name))
			if err != nil {
				t.Fatal(err)
			}
			var n int
			var ok bool
			if tc.video {
				n, ok = p.EncodedVideo(context.Background(), uri(tc.kind, b))
			} else {
				n, ok = p.EncodedImage(context.Background(), uri(tc.kind, b))
			}
			if !ok || n < tc.low || n > tc.high {
				t.Fatalf("count%d known%v outside independent range[%d,%d]", n, ok, tc.low, tc.high)
			}
			t.Logf("metadata estimate: %d media tokens", n)
		})
	}
}
