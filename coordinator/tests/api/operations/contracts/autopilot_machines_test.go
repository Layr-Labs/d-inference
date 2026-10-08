package operations_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"github.com/google/uuid"
)

const autopilotMachinesPath = "/v1/admin/autopilot/machines"
const autopilotMachinesAdminKey = "machine-autopilot-admin-key"

func newAutopilotMachineHTTP(t *testing.T, st store.Store) (*registry.Registry, *api.Server, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{AdminKey: autopilotMachinesAdminKey}, logger)
	server := httptest.NewServer(srv.Handler())
	t.Cleanup(server.Close)
	return reg, srv, server
}

func observeAutopilotMachine(t *testing.T, st store.MachineInventoryStore, session string) string {
	t.Helper()
	machine, err := st.ObserveMachine(context.Background(), store.MachineObservation{
		SessionID: session, AccountID: "private-owner", SEKey: "private-se-" + session,
		VerifiedSerial: "private-serial-" + session, VerifiedAppAttestKey: "private-app-attest-" + session,
		Source: "live_registration", At: time.Now(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return machine.ID
}

func autopilotMachineRequest(t *testing.T, server *httptest.Server, method, path, token, body string, status int) []byte {
	t.Helper()
	req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if method == http.MethodPatch {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != status {
		t.Fatalf("%s %s status=%d want=%d body=%s", method, path, res.StatusCode, status, data)
	}
	if res.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("non-JSON response: %v %s", res.Header, data)
	}
	if status != http.StatusUnauthorized && res.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("machine response may be cached: %v", res.Header)
	}
	if res.Header.Get("Location") != "" {
		t.Fatalf("machine response redirected: %v", res.Header)
	}
	if status >= 400 {
		var result struct {
			Error struct{ Type, Code, Message string }
		}
		if err := json.Unmarshal(data, &result); err != nil || result.Error.Type == "" || result.Error.Code != result.Error.Type || result.Error.Message == "" {
			t.Fatalf("invalid error envelope: %s (%v)", data, err)
		}
	}
	return data
}

type autopilotMachinePage struct {
	Machines  []registry.MachineAutopilotStatus `json:"machines"`
	NextAfter string                            `json:"next_after"`
}

func listAutopilotMachines(t *testing.T, server *httptest.Server, query string) autopilotMachinePage {
	t.Helper()
	body := autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath+query, autopilotMachinesAdminKey, "", http.StatusOK)
	var result autopilotMachinePage
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if result.Machines == nil {
		t.Fatalf("machines must be an array: %s", body)
	}
	return result
}

func patchAutopilotMachine(t *testing.T, server *httptest.Server, id string, mode store.MachineAutopilotMode) registry.MachineAutopilotStatus {
	t.Helper()
	body := autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+id, autopilotMachinesAdminKey, fmt.Sprintf(`{"desired_mode":%q}`, mode), http.StatusOK)
	var result struct {
		Machine registry.MachineAutopilotStatus `json:"machine"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if result.Machine.MachineID == "" || result.Machine.Sessions == nil {
		t.Fatalf("invalid machine envelope: %s", body)
	}
	return result.Machine
}

func TestAutopilotMachinesRequireAdminBeforeParsing(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, srv, server := newAutopilotMachineHTTP(t, st)
	id := observeAutopilotMachine(t, st, "auth-session")
	srv.SetAdminEmails([]string{"admin@darkbloom.ai"})
	if err := st.CreateUser(&store.User{AccountID: "machine-admin", PrivyUserID: "did:privy:machine-admin", Email: "admin@darkbloom.ai"}); err != nil {
		t.Fatal(err)
	}
	sessions := testkit.NewSessions(t, srv, st)
	userJWT := sessions.Token("ordinary-user")
	adminJWT := sessions.Token("machine-admin")
	userKey, err := st.CreateKeyForAccount("ordinary-user")
	if err != nil {
		t.Fatal(err)
	}
	for _, auth := range []struct {
		name, token string
		status      int
	}{
		{"missing", "", http.StatusUnauthorized},
		{"invalid key", "invalid-key", http.StatusUnauthorized},
		{"invalid JWT", "eyJinvalid.invalid.invalid", http.StatusUnauthorized},
		{"ordinary API key", userKey, http.StatusForbidden},
		{"ordinary JWT", userJWT, http.StatusForbidden},
	} {
		t.Run(auth.name, func(t *testing.T) {
			for _, req := range []struct{ method, path, body string }{
				{http.MethodGet, autopilotMachinesPath, ""},
				{http.MethodGet, autopilotMachinesPath + "?after=*&limit=0", ""},
				{http.MethodPatch, autopilotMachinesPath + "/" + id, `{"desired_mode":"live"}`},
				{http.MethodPatch, autopilotMachinesPath + "/" + id, `{"malformed":`},
				{http.MethodPatch, autopilotMachinesPath + "/*", `{"desired_mode":"live"}`},
			} {
				autopilotMachineRequest(t, server, req.method, req.path, auth.token, req.body, auth.status)
			}
		})
	}
	page := listAutopilotMachines(t, server, "")
	if len(page.Machines) != 1 || page.Machines[0].DesiredMode != store.MachineAutopilotShadow || page.Machines[0].Revision != 0 {
		t.Fatalf("rejected request changed intent: %+v", page)
	}
	if got := patchAutopilotMachine(t, server, id, store.MachineAutopilotLive); got.DesiredMode != store.MachineAutopilotLive || got.Revision != 1 {
		t.Fatalf("admin key did not set intent: %+v", got)
	}
	body := autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+id, adminJWT, `{"desired_mode":"shadow"}`, http.StatusOK)
	var result struct {
		Machine registry.MachineAutopilotStatus
	}
	if err := json.Unmarshal(body, &result); err != nil || result.Machine.DesiredMode != store.MachineAutopilotShadow || result.Machine.Revision != 2 {
		t.Fatalf("Privy admin did not set intent: %s (%v)", body, err)
	}
	autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, adminJWT, "", http.StatusOK)
}

func TestAutopilotMachinesRejectInvalidJSONWithoutChangingIntent(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	id := observeAutopilotMachine(t, st, "json-session")
	for _, tc := range []struct{ name, body string }{
		{"empty", ""},
		{"malformed", `{"desired_mode":`},
		{"null", `null`},
		{"array", `[{"desired_mode":"live"}]`},
		{"string", `"live"`},
		{"missing", `{}`},
		{"null mode", `{"desired_mode":null}`},
		{"empty mode", `{"desired_mode":""}`},
		{"unknown mode", `{"desired_mode":"disabled"}`},
		{"uppercase mode", `{"desired_mode":"LIVE"}`},
		{"padded mode", `{"desired_mode":" live "}`},
		{"number mode", `{"desired_mode":1}`},
		{"boolean mode", `{"desired_mode":true}`},
		{"object mode", `{"desired_mode":{}}`},
		{"array mode", `{"desired_mode":["live"]}`},
		{"unknown field", `{"desired_mode":"live","paused":false}`},
		{"unknown field first", `{"paused":false,"desired_mode":"live"}`},
		{"legacy allowlist", `{"desired_mode":"live","live_machine_ids":[]}`},
		{"duplicate key", `{"desired_mode":"shadow","desired_mode":"live"}`},
		{"case alias", `{"DESIRED_MODE":"live"}`},
		{"trailing object", `{"desired_mode":"live"}{}`},
		{"trailing null", `{"desired_mode":"live"}null`},
		{"trailing garbage", `{"desired_mode":"live"}!`},
		{"oversized prefix", strings.Repeat(" ", 1024) + `{"desired_mode":"live"}`},
		{"oversized suffix", `{"desired_mode":"live"}` + strings.Repeat(" ", 1024)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+id, autopilotMachinesAdminKey, tc.body, http.StatusBadRequest)
			page := listAutopilotMachines(t, server, "")
			if len(page.Machines) != 1 || page.Machines[0].DesiredMode != store.MachineAutopilotShadow || page.Machines[0].Revision != 0 {
				t.Fatalf("invalid JSON changed intent: %+v", page)
			}
		})
	}
	body := `{"desired_mode":"live"}`
	body += strings.Repeat(" ", 1024-len(body))
	autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+id, autopilotMachinesAdminKey, body, http.StatusOK)
	if page := listAutopilotMachines(t, server, ""); page.Machines[0].Revision != 1 || page.Machines[0].DesiredMode != store.MachineAutopilotLive {
		t.Fatalf("exact 1 KiB body rejected: %+v", page)
	}
}

func TestAutopilotMachinesValidateIDsAndLimits(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	id := observeAutopilotMachine(t, st, "validation-session")
	for _, invalid := range []string{"bad-id", "*", "private-owner", uuid.Nil.String(), strings.ReplaceAll(id, "-", ""), "{" + id + "}", "urn:uuid:" + id, " " + id, id + " ", id + "/extra"} {
		autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+url.PathEscape(invalid), autopilotMachinesAdminKey, `{"desired_mode":"live"}`, http.StatusBadRequest)
		autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath+"?after="+url.QueryEscape(invalid), autopilotMachinesAdminKey, "", http.StatusBadRequest)
	}
	for _, limit := range []string{"", "0", "-1", "201", "1.5", "one", "null", "999999999999999999999999"} {
		autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath+"?limit="+limit, autopilotMachinesAdminKey, "", http.StatusBadRequest)
	}
	for _, query := range []string{"?after=", "?after=" + id + "&after=" + id, "?limit=1&limit=2", "?after=%zz"} {
		autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath+query, autopilotMachinesAdminKey, "", http.StatusBadRequest)
	}
	autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+uuid.NewString(), autopilotMachinesAdminKey, `{"desired_mode":"live"}`, http.StatusNotFound)
	if page := listAutopilotMachines(t, server, ""); len(page.Machines) != 1 || page.Machines[0].Revision != 0 || page.Machines[0].DesiredMode != store.MachineAutopilotShadow {
		t.Fatalf("invalid requests created or changed machines: %+v", page)
	}
	got := patchAutopilotMachine(t, server, strings.ToUpper(id), store.MachineAutopilotLive)
	if got.MachineID != id || got.DesiredMode != store.MachineAutopilotLive || got.Revision != 1 {
		t.Fatalf("uppercase canonical path not normalized: %+v", got)
	}
	if page := listAutopilotMachines(t, server, "?after="+strings.ToUpper(id)); len(page.Machines) != 0 || page.NextAfter != "" {
		t.Fatalf("uppercase canonical cursor not normalized: %+v", page)
	}
}

func TestAutopilotMachinesKeysetPagination(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	if page := listAutopilotMachines(t, server, ""); len(page.Machines) != 0 || page.NextAfter != "" {
		t.Fatalf("empty page: %+v", page)
	}
	ids := make([]string, 205)
	for i := range ids {
		ids[i] = observeAutopilotMachine(t, st, fmt.Sprintf("page-session-%d", i))
	}
	slices.Sort(ids)
	for _, tc := range []struct {
		query string
		start int
		count int
		next  string
	}{
		{"", 0, 100, ids[99]},
		{"?after=" + ids[99], 100, 100, ids[199]},
		{"?after=" + ids[199], 200, 5, ""},
		{"?limit=200", 0, 200, ids[199]},
		{"?limit=1", 0, 1, ids[0]},
		{"?after=" + ids[203] + "&limit=1", 204, 1, ids[204]},
		{"?after=" + ids[204] + "&limit=1", 205, 0, ""},
		{"?after=ffffffff-ffff-ffff-ffff-ffffffffffff", 205, 0, ""},
	} {
		page := listAutopilotMachines(t, server, tc.query)
		if len(page.Machines) != tc.count || page.NextAfter != tc.next {
			t.Fatalf("query=%q count=%d next=%q want count=%d next=%q", tc.query, len(page.Machines), page.NextAfter, tc.count, tc.next)
		}
		for i, machine := range page.Machines {
			if machine.MachineID != ids[tc.start+i] || machine.DesiredMode != store.MachineAutopilotShadow || machine.Revision != 0 || machine.Sessions == nil || len(machine.Sessions) != 0 {
				t.Fatalf("query=%q index=%d machine=%+v", tc.query, i, machine)
			}
		}
	}
}
