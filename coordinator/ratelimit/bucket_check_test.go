package ratelimit

import (
	"testing"
	"time"

	"golang.org/x/time/rate"
)

func TestBucketCheckRefillDoesNotConsume(t *testing.T) {
	now := time.Now()
	bucket := rate.NewLimiter(1, 1)
	if !bucket.AllowN(now, 1) {
		t.Fatal("initial token unavailable")
	}
	for _, elapsed := range []time.Duration{0, time.Second / 2, time.Second, 2 * time.Second} {
		at := now.Add(elapsed)
		before := bucket.TokensAt(at)
		allowed, retry := checkBucket(bucket, at, 1, 1, 1)
		if allowed != (elapsed >= time.Second) {
			t.Fatalf("at %s allowed=%v", elapsed, allowed)
		}
		if !allowed && retry <= 0 {
			t.Fatal("rejected check lost retry hint")
		}
		if after := bucket.TokensAt(at); after != before {
			t.Fatalf("check consumed capacity: before=%f after=%f", before, after)
		}
	}
	if !bucket.AllowN(now.Add(time.Second), 1) {
		t.Fatal("successful refill checks consumed the token")
	}
}

func TestBucketChecksKeepLimitAndClampRules(t *testing.T) {
	fixed := New(Config{RPS: 0.000001, Burst: 2})
	if ok, _ := fixed.CheckN("acct", 3); ok {
		t.Fatal("fixed check accepted more than burst")
	}
	if ok, _ := fixed.CheckN("acct", 2); !ok {
		t.Fatal("rejection consumed fixed quota")
	}
	if ok, _ := fixed.AllowN("acct", 2); !ok {
		t.Fatal("successful check consumed fixed quota")
	}
	if ok, retry := fixed.CheckN("acct", 1); ok || retry != maxRetryAfter {
		t.Fatalf("drained fixed check=%v retry=%s", ok, retry)
	}
	variable := New(Config{})
	if ok, _ := variable.CheckNWithRate("key", 100, 0.000001, 2); !ok {
		t.Fatal("per-key oversized charge must clamp to burst")
	}
	if ok, _ := variable.AllowNWithRate("key", 2, 0.000001, 2); !ok {
		t.Fatal("successful check consumed variable quota")
	}
	if ok, _ := variable.CheckNWithRate("key", 1, 0.000001, 2); ok {
		t.Fatal("drained variable bucket admitted")
	}
	if ok, _ := variable.CheckNWithRate("key", 100, 0, 2); !ok {
		t.Fatal("zero rate must remain unlimited")
	}
	if ok, _ := variable.CheckNWithRate("key", 100, 1, 0); !ok {
		t.Fatal("zero burst must remain unlimited")
	}
}
