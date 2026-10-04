package promptcontract

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestNextBackoffDoublesUntilMaximum(t *testing.T) {
	tests := []struct{ current, maximum, want time.Duration }{
		{time.Second, 10 * time.Second, 2 * time.Second},
		{4 * time.Second, 10 * time.Second, 8 * time.Second},
		{5 * time.Second, 10 * time.Second, 10 * time.Second},
		{20 * time.Second, 10 * time.Second, 10 * time.Second},
	}
	for _, test := range tests {
		if got := nextBackoff(test.current, test.maximum); got != test.want {
			t.Fatalf("nextBackoff(%v, %v) = %v, want %v", test.current, test.maximum, got, test.want)
		}
	}
}

func TestProcessRSSBytes(t *testing.T) {
	if got := processRSSBytes(0); got != 0 {
		t.Fatalf("pid 0 rss = %d", got)
	}
	if got := processRSSBytes(-5); got != 0 {
		t.Fatalf("negative pid rss = %d", got)
	}
	// The test process itself is alive and has resident memory on both
	// /proc systems and ps systems.
	if got := processRSSBytes(os.Getpid()); got == 0 || got%1024 != 0 {
		t.Fatalf("own rss = %d, want a positive multiple of 1024", got)
	}

	// A process that has exited and been reaped has no rss.
	command := exec.Command("true")
	if err := command.Run(); err != nil {
		t.Skipf("cannot run true: %v", err)
	}
	if got := processRSSBytes(command.ProcessState.Pid()); got != 0 {
		t.Fatalf("exited process rss = %d, want 0", got)
	}
}

func TestChildExitReason(t *testing.T) {
	if got := childExitReason(errors.New("  wait failed  "), nil); got != "wait failed" {
		t.Fatalf("error reason = %q", got)
	}
	long := strings.Repeat("a", maxSupervisorReasonBytes) + "tail"
	if got := childExitReason(errors.New(long), nil); len(got) != maxSupervisorReasonBytes || !strings.HasSuffix(got, "tail") {
		t.Fatalf("long reason kept %d bytes, suffix tail=%v", len(got), strings.HasSuffix(got, "tail"))
	}
	if got := childExitReason(nil, nil); got != "child exited without process state" {
		t.Fatalf("nil state reason = %q", got)
	}
	command := exec.Command("sh", "-c", "exit 3")
	_ = command.Run()
	if got := childExitReason(nil, command.ProcessState); got != "child exited with status exit status 3" {
		t.Fatalf("state reason = %q", got)
	}
}

func TestBoundedSupervisorTextKeepsTail(t *testing.T) {
	if got := boundedSupervisorText(" abcdef ", 0); got != "abcdef" {
		t.Fatalf("unbounded = %q", got)
	}
	if got := boundedSupervisorText("abcdef", 3); got != "def" {
		t.Fatalf("bounded = %q", got)
	}
}

func TestTailBufferKeepsNewestBytes(t *testing.T) {
	buffer := newTailBuffer(5)
	for _, chunk := range []string{"ab", "cd", "efg"} {
		if n, err := buffer.Write([]byte(chunk)); err != nil || n != len(chunk) {
			t.Fatalf("write %q = %d, %v", chunk, n, err)
		}
	}
	if got := buffer.String(); got != "cdefg" {
		t.Fatalf("after overflow = %q, want cdefg", got)
	}
	// A write at least as large as the buffer replaces it with its own tail.
	if n, _ := buffer.Write([]byte("0123456")); n != 7 {
		t.Fatalf("large write count = %d", n)
	}
	if got := buffer.String(); got != "23456" {
		t.Fatalf("after large write = %q, want 23456", got)
	}

	disabled := newTailBuffer(0)
	if n, err := disabled.Write([]byte("ignored")); err != nil || n != 7 {
		t.Fatalf("disabled write = %d, %v", n, err)
	}
	if got := disabled.String(); got != "" {
		t.Fatalf("disabled buffer kept %q", got)
	}
}
