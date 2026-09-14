package attempt

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
)

func TestCancelSendFailureReason(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{registry.ErrProviderWriterQueueFull, "queue_full"},
		{registry.ErrProviderWriterStopped, "writer_stopped"},
		{context.DeadlineExceeded, "ctx"},
		{context.Canceled, "ctx"},
		{errors.New("boom"), "other"},
	}
	for _, c := range cases {
		if got := cancelSendFailureReason(c.err); got != c.want {
			t.Errorf("cancelSendFailureReason(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}
