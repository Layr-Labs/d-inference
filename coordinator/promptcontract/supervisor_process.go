package promptcontract

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

func sleepContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func nextBackoff(current, maximum time.Duration) time.Duration {
	if current >= maximum/2 {
		return maximum
	}
	return current * 2
}

func stopTimer(timer *time.Timer) {
	if timer == nil || !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
}

func processRSSBytes(pid int) uint64 {
	if pid <= 0 {
		return 0
	}
	if data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/statm"); err == nil {
		return rssBytesFromStatm(data, os.Getpagesize())
	}
	output, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0
	}
	kib, err := strconv.ParseUint(strings.TrimSpace(string(output)), 10, 64)
	if err != nil || kib > ^uint64(0)/1024 {
		return 0
	}
	return kib * 1024
}

func rssBytesFromStatm(data []byte, pageSize int) uint64 {
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0
	}
	residentPages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	if pageSize <= 0 || residentPages > ^uint64(0)/uint64(pageSize) {
		return 0
	}
	return residentPages * uint64(pageSize)
}

func exceedsRSSLimit(rssBytes uint64, limitMiB int) bool {
	if rssBytes == 0 || limitMiB <= 0 || uint64(limitMiB) > ^uint64(0)/(1<<20) {
		return false
	}
	return rssBytes > uint64(limitMiB)*(1<<20)
}

func childExitReason(err error, state *os.ProcessState) string {
	if err != nil {
		return boundedSupervisorText(err.Error(), maxSupervisorReasonBytes)
	}
	if state == nil {
		return "child exited without process state"
	}
	return fmt.Sprintf("child exited with status %s", state.String())
}

func boundedSupervisorText(value string, maximum int) string {
	value = strings.TrimSpace(value)
	if maximum <= 0 || len(value) <= maximum {
		return value
	}
	return value[len(value)-maximum:]
}

type tailBuffer struct {
	mu      sync.Mutex
	maximum int
	data    []byte
}

func newTailBuffer(maximum int) *tailBuffer {
	return &tailBuffer{maximum: maximum, data: make([]byte, 0, maximum)}
}

func (b *tailBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	written := len(data)
	if b.maximum <= 0 {
		return written, nil
	}
	if len(data) >= b.maximum {
		b.data = append(b.data[:0], data[len(data)-b.maximum:]...)
		return written, nil
	}
	overflow := len(b.data) + len(data) - b.maximum
	if overflow > 0 {
		copy(b.data, b.data[overflow:])
		b.data = b.data[:len(b.data)-overflow]
	}
	b.data = append(b.data, data...)
	return written, nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(bytes.Clone(b.data))
}
