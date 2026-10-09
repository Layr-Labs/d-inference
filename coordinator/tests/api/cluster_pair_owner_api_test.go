package api_test

// What the site reads to draw a cluster card: the owner's cluster listing and
// the cluster fields on the owner's machine rows. Both are scoped to the
// authenticated account and follow the dashboard's rule that device identity
// is never returned.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	fleetview "github.com/eigeninference/d-inference/coordinator/internal/api/accounts/fleetview"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// ownerGet performs an authenticated dashboard read as account.
func (d *pairDeployment) ownerGet(t *testing.T, sessions *testkit.Sessions, account, path string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, path, nil)
	if account != "" {
		request.Header.Set("Authorization", "Bearer "+sessions.Token(account))
	}
	recorder := httptest.NewRecorder()
	d.fixture.Server.Handler().ServeHTTP(recorder, request)
	return recorder
}

func requireNoDeviceIdentity(t *testing.T, body string) {
	t.Helper()
	for _, secret := range []string{"serial-leader", "serial-follower", `"serial_number"`, `"account_id":"account-two"`} {
		if strings.Contains(body, secret) {
			t.Fatalf("owner view leaked %q: %s", secret, body)
		}
	}
}

func TestOwnerListsItsClusterPair(t *testing.T) {
	s := newServingPair(t)
	sessions := testkit.NewSessions(t, s.fixture.Server, s.fixture.Store)

	if got := s.ownerGet(t, sessions, "", "/v1/me/cluster-pairs"); got.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated cluster listing: status %d", got.Code)
	}
	got := s.ownerGet(t, sessions, "account-one", "/v1/me/cluster-pairs")
	if got.Code != http.StatusOK {
		t.Fatalf("owner cluster listing: status %d body %s", got.Code, got.Body)
	}
	requireNoDeviceIdentity(t, got.Body.String())
	var listed fleetview.ClusterPairsResponse
	if err := json.Unmarshal(got.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	if !listed.Enabled || listed.RequestScope != "owner_account" || listed.LifetimeSeconds != 300 || len(listed.Pairs) != 1 {
		t.Fatalf("owner cluster listing = %+v", listed)
	}
	pair := listed.Pairs[0]
	if pair.ClusterID != "studio-pair" || pair.PolicySHA256 != s.policy || pair.ApprovalID != pairApproval || pair.Model != pairModel ||
		pair.State != "active" || pair.Waiting != "" || !pair.ServingReady || pair.Epoch != s.prepares[0].Epoch ||
		pair.ExpiresAt == nil || pair.RemainingLifetimeSeconds <= 240 || pair.RemainingLifetimeSeconds > 300 ||
		pair.ReformExpectedAt != nil || pair.Failures != 0 {
		t.Fatalf("serving pair is misreported: %+v", pair)
	}
	leader, follower := pair.Members[0], pair.Members[1]
	if leader.Rank != 0 || leader.Role != "leader" || !leader.Attached || leader.ProviderID != s.leaderProvider.ID ||
		leader.ChipName != pairChip || leader.MemoryGB != 64 ||
		follower.Rank != 1 || follower.Role != "follower" || !follower.Attached || follower.ProviderID != s.followerProvider.ID {
		t.Fatalf("pair members are misreported: %+v", pair.Members)
	}

	// Another account is told the feature is on and sees no cluster.
	other := s.ownerGet(t, sessions, "account-two", "/v1/me/cluster-pairs")
	var none fleetview.ClusterPairsResponse
	if err := json.Unmarshal(other.Body.Bytes(), &none); err != nil || other.Code != http.StatusOK {
		t.Fatalf("another account's cluster listing: status %d err %v", other.Code, err)
	}
	if !none.Enabled || len(none.Pairs) != 0 || strings.Contains(other.Body.String(), "studio-pair") ||
		strings.Contains(other.Body.String(), s.leaderProvider.ID) {
		t.Fatalf("another account saw the pair: %s", other.Body)
	}
}

func TestOwnerMachineRowsCarryTheirClusterRole(t *testing.T) {
	s := newServingPair(t)
	sessions := testkit.NewSessions(t, s.fixture.Server, s.fixture.Store)
	solo := testkit.RegisterBuildsProvider(s.fixture.Registry, "solo-of-account-one", "some-solo-model")
	solo.Mu().Lock()
	solo.AccountID = "account-one"
	solo.Mu().Unlock()

	got := s.ownerGet(t, sessions, "account-one", "/v1/me/providers")
	if got.Code != http.StatusOK {
		t.Fatalf("owner machine listing: status %d body %s", got.Code, got.Body)
	}
	requireNoDeviceIdentity(t, got.Body.String())
	var listed fleetview.ProvidersResponse
	if err := json.Unmarshal(got.Body.Bytes(), &listed); err != nil {
		t.Fatal(err)
	}
	rows := map[string]fleetview.Provider{}
	for _, row := range listed.Providers {
		rows[row.ID] = row
	}
	if len(rows) != 3 {
		t.Fatalf("owner lists %d machines, want the two members and the solo provider", len(rows))
	}
	if row := rows[solo.ID]; row.ExecutionRole != "solo" || row.Cluster != nil {
		t.Fatalf("solo machine row: role %q cluster %+v", row.ExecutionRole, row.Cluster)
	}
	for rank, want := range []struct{ id, role, peer string }{
		{s.leaderProvider.ID, "leader", s.followerProvider.ID},
		{s.followerProvider.ID, "follower", s.leaderProvider.ID},
	} {
		row := rows[want.id]
		if row.ExecutionRole != "cluster_member" || row.Cluster == nil {
			t.Fatalf("rank%d machine row has no cluster: %+v", rank, row)
		}
		if c := *row.Cluster; c.ClusterID != "studio-pair" || c.Rank != rank || c.Role != want.role || c.PolicySHA256 != s.policy ||
			c.PairState != "active" || c.Waiting != "" || !c.ServingReady || c.PeerProviderID != want.peer {
			t.Fatalf("rank%d cluster block is misreported: %+v", rank, c)
		}
	}
}

// Without cluster pair configuration the owner views say so and carry no pair
// state; a member's row still names the role and cluster it registered.
func TestOwnerViewsWithoutClusterPairConfiguration(t *testing.T) {
	d := newPairDeployment(t, func(*api.ServerConfig, string) {})
	sessions := testkit.NewSessions(t, d.fixture.Server, d.fixture.Store)
	_, leaderProvider := d.member(t, "account-one", "studio-pair", "serial-leader", 0)

	got := d.ownerGet(t, sessions, "account-one", "/v1/me/cluster-pairs")
	var listed fleetview.ClusterPairsResponse
	if err := json.Unmarshal(got.Body.Bytes(), &listed); err != nil || got.Code != http.StatusOK {
		t.Fatalf("cluster listing without configuration: status %d err %v", got.Code, err)
	}
	if listed.Enabled || len(listed.Pairs) != 0 {
		t.Fatalf("cluster listing without configuration = %+v", listed)
	}
	rows := d.ownerGet(t, sessions, "account-one", "/v1/me/providers")
	var machines fleetview.ProvidersResponse
	if err := json.Unmarshal(rows.Body.Bytes(), &machines); err != nil || len(machines.Providers) != 1 {
		t.Fatalf("machine listing without configuration: %s", rows.Body)
	}
	row := machines.Providers[0]
	if row.ID != leaderProvider.ID || row.ExecutionRole != "cluster_member" || row.Cluster == nil ||
		row.Cluster.ClusterID != "studio-pair" || row.Cluster.Role != "leader" ||
		row.Cluster.PairState != "" || row.Cluster.ServingReady || row.Cluster.PeerProviderID != "" {
		t.Fatalf("member row without configuration: %+v cluster %+v", row, row.Cluster)
	}
}
