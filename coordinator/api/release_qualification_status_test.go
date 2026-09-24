package api

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// qualificationStatusResponse decodes the POST /v1/releases/qualification
// response body. It is a test-local shape (SPEC.md G1-G8, CONTRACT.md C1) and
// deliberately does not reference any new production symbol: this file only
// ever calls the handler over HTTP through qualificationCall.
type qualificationStatusResponse struct {
	Status           string   `json:"status"`
	BinaryHash       string   `json:"binary_hash,omitempty"`
	ApprovedBy       string   `json:"approved_by,omitempty"`
	ApprovedAt       string   `json:"approved_at,omitempty"`
	Evidence         string   `json:"evidence,omitempty"`
	RevokedAt        string   `json:"revoked_at,omitempty"`
	RevokedBy        string   `json:"revoked_by,omitempty"`
	RevocationReason string   `json:"revocation_reason,omitempty"`
	MismatchedFields []string `json:"mismatched_fields,omitempty"`
}

func withExtraField(t *testing.T, body any, key string, value any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	m[key] = value
	return m
}

func decodeQualificationStatus(t *testing.T, body []byte) qualificationStatusResponse {
	t.Helper()
	var resp qualificationStatusResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode qualification status response: %v (%s)", err, body)
	}
	return resp
}

// G1: missing/wrong release key -> 401; the admin key as bearer does not
// substitute for the release key.
func TestReleaseQualificationStatusRequiresReleaseKey(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	body := registrationBody(b)
	for _, tc := range []struct{ name, token string }{
		{"missing key", ""},
		{"wrong key", "wrong-release-key"},
		{"admin key", "admin-key"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := qualificationCall(t, s, "POST", "/v1/releases/qualification", tc.token, body)
			if w.Code != 401 {
				t.Fatalf("%s: status %d %s, want 401", tc.name, w.Code, w.Body)
			}
		})
	}
}

// G2: no qualification row -> 200 {"status":"pending"}.
func TestReleaseQualificationStatusPendingWhenNoRow(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", registrationBody(b))
	if w.Code != 200 {
		t.Fatalf("status: %d %s, want 200", w.Code, w.Body)
	}
	resp := decodeQualificationStatus(t, w.Body.Bytes())
	if resp.Status != "pending" {
		t.Fatalf("status = %q, want pending", resp.Status)
	}
	if resp.ApprovedBy != "" || resp.Evidence != "" || resp.RevocationReason != "" || len(resp.MismatchedFields) != 0 {
		t.Fatalf("pending response carried attribution/mismatch fields: %+v", resp)
	}
}

// G3: an exact approved identity returns "approved" plus attribution and evidence.
func TestReleaseQualificationStatusApprovedExactIdentity(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", qualificationBody(b)); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", registrationBody(b))
	if w.Code != 200 {
		t.Fatalf("status: %d %s, want 200", w.Code, w.Body)
	}
	resp := decodeQualificationStatus(t, w.Body.Bytes())
	if resp.Status != "approved" {
		t.Fatalf("status = %q, want approved", resp.Status)
	}
	if resp.ApprovedBy == "" || resp.ApprovedAt == "" || resp.Evidence == "" {
		t.Fatalf("approved response missing attribution/evidence: %+v", resp)
	}
	if len(resp.MismatchedFields) != 0 {
		t.Fatalf("approved response carried mismatched_fields: %v", resp.MismatchedFields)
	}
}

// G4: a revoked row returns "revoked" with the reason. Revocation is keyed by
// binary hash and wins over everything, even when other identity fields in
// the request differ from what was approved.
func TestReleaseQualificationStatusRevokedWinsOverMismatch(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", qualificationBody(b)); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}
	const reason = "withdraw qualification for cause"
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds/revoke", "admin-key",
		map[string]string{"binary_hash": b.Release.BinaryHash, "reason": reason}); w.Code != 200 {
		t.Fatalf("revoke: %d %s", w.Code, w.Body)
	}

	differing := b
	differing.SourceCommit = strings.Repeat("1", 40)
	differing.CIRunID = "999"

	for name, body := range map[string]any{
		"exact identity":     registrationBody(b),
		"differing identity": registrationBody(differing),
	} {
		t.Run(name, func(t *testing.T) {
			w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", body)
			if w.Code != 200 {
				t.Fatalf("status: %d %s, want 200", w.Code, w.Body)
			}
			resp := decodeQualificationStatus(t, w.Body.Bytes())
			if resp.Status != "revoked" {
				t.Fatalf("status = %q, want revoked even with a differing field", resp.Status)
			}
			if resp.RevocationReason != reason {
				t.Fatalf("revocation_reason = %q, want %q", resp.RevocationReason, reason)
			}
		})
	}
}

// G5: a difference in source_commit, ci_run_id, code_directory_hash,
// bundle_hash or metallib_hash returns "mismatched" naming that field, while
// binary_hash (the row key) stays fixed so the approved row is still found.
func TestReleaseQualificationStatusMismatchedFields(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", qualificationBody(b)); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}

	cases := []struct {
		field  string
		mutate func(store.AppAttestBuildIdentity) store.AppAttestBuildIdentity
	}{
		{"source_commit", func(id store.AppAttestBuildIdentity) store.AppAttestBuildIdentity {
			id.SourceCommit = strings.Repeat("1", 40)
			return id
		}},
		{"ci_run_id", func(id store.AppAttestBuildIdentity) store.AppAttestBuildIdentity {
			id.CIRunID = "999"
			return id
		}},
		{"code_directory_hash", func(id store.AppAttestBuildIdentity) store.AppAttestBuildIdentity {
			id.CodeDirectoryHash = strings.Repeat("9", 64)
			return id
		}},
		{"bundle_hash", func(id store.AppAttestBuildIdentity) store.AppAttestBuildIdentity {
			id.Release.BundleHash = strings.Repeat("9", 64)
			return id
		}},
		{"metallib_hash", func(id store.AppAttestBuildIdentity) store.AppAttestBuildIdentity {
			id.Release.MetallibHash = strings.Repeat("9", 64)
			return id
		}},
	}

	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			mutated := tc.mutate(b)
			if mutated.Release.BinaryHash != b.Release.BinaryHash {
				t.Fatalf("%s: test bug, binary_hash must stay fixed", tc.field)
			}
			w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", registrationBody(mutated))
			if w.Code != 200 {
				t.Fatalf("%s: status %d %s, want 200", tc.field, w.Code, w.Body)
			}
			resp := decodeQualificationStatus(t, w.Body.Bytes())
			if resp.Status != "mismatched" {
				t.Fatalf("%s: status = %q, want mismatched", tc.field, resp.Status)
			}
			found := false
			for _, f := range resp.MismatchedFields {
				if f == tc.field {
					found = true
				}
			}
			if !found {
				t.Fatalf("%s: mismatched_fields = %v, want to contain %q", tc.field, resp.MismatchedFields, tc.field)
			}
		})
	}
}

// G6: every call to the new endpoint leaves the qualification store and the
// release catalog unchanged. It is read-only regardless of the status it
// reports (pending, approved or mismatched).
func TestReleaseQualificationStatusNeverMutatesStoreOrRegistersRelease(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "admin-key", qualificationBody(b)); w.Code != 200 {
		t.Fatalf("approve: %d %s", w.Code, w.Body)
	}

	before, err := st.ListAppAttestBuildQualifications(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	beforeLatest := qualificationCall(t, s, "GET", "/v1/releases/latest", "", nil)

	unknown := b
	unknown.Release.BinaryHash = strings.Repeat("0", 64)
	mismatched := b
	mismatched.CIRunID = "999"

	calls := []struct {
		name string
		body any
		want string
	}{
		{"pending", registrationBody(unknown), "pending"},
		{"approved", registrationBody(b), "approved"},
		{"mismatched", registrationBody(mismatched), "mismatched"},
	}
	for _, c := range calls {
		w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", c.body)
		if w.Code != 200 {
			t.Fatalf("%s: status %d %s, want 200", c.name, w.Code, w.Body)
		}
		resp := decodeQualificationStatus(t, w.Body.Bytes())
		if resp.Status != c.want {
			t.Fatalf("%s: status = %q, want %q", c.name, resp.Status, c.want)
		}
	}

	after, err := st.ListAppAttestBuildQualifications(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("qualification status calls mutated the build store: before=%+v after=%+v", before, after)
	}
	if st.GetLatestRelease(b.Release.Platform) != nil {
		t.Fatal("qualification status calls registered a release")
	}
	afterLatest := qualificationCall(t, s, "GET", "/v1/releases/latest", "", nil)
	if beforeLatest.Code != afterLatest.Code || beforeLatest.Body.String() != afterLatest.Body.String() {
		t.Fatalf("GET /v1/releases/latest changed after qualification status calls: before=%d %s after=%d %s",
			beforeLatest.Code, beforeLatest.Body, afterLatest.Code, afterLatest.Body)
	}
}

// G7: an unreadable qualification store returns 503 qualification_unavailable.
func TestReleaseQualificationStatusStoreOutageFailsClosed(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	unavailable := NewServer(s.registry, &unavailableBuildStore{st}, ServerConfig{}, s.logger)
	t.Cleanup(unavailable.Close)
	unavailable.SetReleaseKey("release-key")
	unavailable.SetAdminKey("admin-key")
	unavailable.SetR2CDNURL(s.r2CDNURL)
	unavailable.appAttestShadow = s.appAttestShadow

	w := qualificationCall(t, unavailable, "POST", "/v1/releases/qualification", "release-key", registrationBody(b))
	if w.Code != 503 {
		t.Fatalf("store outage: %d %s, want 503", w.Code, w.Body)
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode error body: %v (%s)", err, w.Body)
	}
	errBody, _ := resp["error"].(map[string]any)
	if errBody == nil || errBody["type"] != "qualification_unavailable" {
		t.Fatalf("error body = %v, want type qualification_unavailable", resp)
	}
}

// G8: the release key cannot approve a build through the admin endpoint, and
// no row is created for it.
func TestReleaseQualificationStatusReleaseKeyCannotApproveBuild(t *testing.T) {
	s, st, b := qualificationReleaseFixture(t)
	if w := qualificationCall(t, s, "POST", "/v1/admin/app-attest/builds", "release-key", qualificationBody(b)); w.Code >= 200 && w.Code < 300 {
		t.Fatalf("release key approved a build: %d %s", w.Code, w.Body)
	}
	rows, err := st.ListAppAttestBuildQualifications(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range rows {
		if q.Release.BinaryHash == b.Release.BinaryHash {
			t.Fatalf("release key created a qualification row: %+v", q)
		}
	}
}

// Invalid identity (fails store.AppAttestBuildIdentity.Validate) -> 400.
func TestReleaseQualificationStatusRejectsInvalidIdentity(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	req := registrationBody(b)
	req.CodeDirectoryHash = "short"
	w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", req)
	if w.Code != 400 {
		t.Fatalf("invalid identity: %d %s, want 400", w.Code, w.Body)
	}
}

// Unknown JSON field is rejected the same way registerReleaseRequest is
// decoded for POST /v1/releases (DisallowUnknownFields) -> 400.
func TestReleaseQualificationStatusRejectsUnknownField(t *testing.T) {
	s, _, b := qualificationReleaseFixture(t)
	body := withExtraField(t, registrationBody(b), "unexpected_field", "nope")
	w := qualificationCall(t, s, "POST", "/v1/releases/qualification", "release-key", body)
	if w.Code != 400 {
		t.Fatalf("unknown field: %d %s, want 400", w.Code, w.Body)
	}
}
