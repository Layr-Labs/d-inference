package leaderboard

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	DefaultLimit = 25
	MaxLimit     = 100
)

type Scope string

const (
	ScopeAccount Scope = "account"
	ScopeNode    Scope = "node"
)

type Window string

const (
	Window24h Window = "24h"
	Window7d  Window = "7d"
	Window30d Window = "30d"
	WindowAll Window = "all"
)

type Query struct {
	Scope  Scope
	Window Window
	Limit  int
}

type Overview struct {
	RegisteredNodes      int64     `json:"registered_nodes"`
	ActiveNodes          int64     `json:"active_nodes"`
	LinkedAccounts       int64     `json:"linked_accounts"`
	HardwareTrustedNodes int64     `json:"hardware_trusted_nodes"`
	MDAVerifiedNodes     int64     `json:"mda_verified_nodes"`
	TotalEarnedMicroUSD  int64     `json:"total_earned_micro_usd"`
	TotalEarnedUSD       string    `json:"total_earned_usd"`
	TotalJobs            int64     `json:"total_jobs"`
	Earned24hMicroUSD    int64     `json:"earned_24h_micro_usd"`
	Earned24hUSD         string    `json:"earned_24h_usd"`
	Jobs24h              int64     `json:"jobs_24h"`
	GeneratedAt          time.Time `json:"generated_at"`
}

type Entry struct {
	Rank               int       `json:"rank"`
	Alias              string    `json:"alias"`
	EarnedMicroUSD     int64     `json:"earned_micro_usd"`
	EarnedUSD          string    `json:"earned_usd"`
	Jobs               int64     `json:"jobs"`
	AvgPerJobUSD       string    `json:"avg_per_job_usd"`
	PromptTokens       int64     `json:"prompt_tokens"`
	CompletionTokens   int64     `json:"completion_tokens"`
	TotalTokens        int64     `json:"total_tokens"`
	ModelsServed       int64     `json:"models_served"`
	NodeCount          int64     `json:"node_count"`
	LastActiveAt       time.Time `json:"last_active_at"`
	LastActiveRelative string    `json:"last_active_relative"`
}

type Leaderboard struct {
	Scope       Scope     `json:"scope"`
	Window      Window    `json:"window"`
	Limit       int       `json:"limit"`
	Backend     string    `json:"backend"`
	GeneratedAt time.Time `json:"generated_at"`
	Entries     []Entry   `json:"entries"`
}

type rawEntry struct {
	StableID         string
	EarnedMicroUSD   int64
	Jobs             int64
	PromptTokens     int64
	CompletionTokens int64
	ModelsServed     int64
	NodeCount        int64
	LastActiveAt     time.Time
}

type Aliaser interface {
	Alias(kind, stableID string) string
}

type Store interface {
	Backend() string
	Ping(ctx context.Context) error
	Close()
	Overview(ctx context.Context) (Overview, error)
	EarningsLeaderboard(ctx context.Context, query Query) ([]rawEntry, error)
}

type Service struct {
	store   Store
	aliaser Aliaser
	now     func() time.Time
}

func NewService(store Store, aliaser Aliaser, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{
		store:   store,
		aliaser: aliaser,
		now:     now,
	}
}

func (s *Service) Backend() string {
	return s.store.Backend()
}

func (s *Service) Ping(ctx context.Context) error {
	return s.store.Ping(ctx)
}

func (s *Service) Close() {
	s.store.Close()
}

func (s *Service) Overview(ctx context.Context) (Overview, error) {
	overview, err := s.store.Overview(ctx)
	if err != nil {
		return Overview{}, err
	}
	overview.TotalEarnedUSD = formatUSD(overview.TotalEarnedMicroUSD)
	overview.Earned24hUSD = formatUSD(overview.Earned24hMicroUSD)
	overview.GeneratedAt = s.now().UTC()
	return overview, nil
}

func (s *Service) EarningsLeaderboard(ctx context.Context, query Query) (Leaderboard, error) {
	query = normalizeQuery(query)
	if err := validateQuery(query); err != nil {
		return Leaderboard{}, err
	}

	rows, err := s.store.EarningsLeaderboard(ctx, query)
	if err != nil {
		return Leaderboard{}, err
	}

	generatedAt := s.now().UTC()
	entries := make([]Entry, 0, len(rows))
	for i, row := range rows {
		kind := string(query.Scope)
		totalTokens := row.PromptTokens + row.CompletionTokens
		entries = append(entries, Entry{
			Rank:               i + 1,
			Alias:              s.aliaser.Alias(kind, row.StableID),
			EarnedMicroUSD:     row.EarnedMicroUSD,
			EarnedUSD:          formatUSD(row.EarnedMicroUSD),
			Jobs:               row.Jobs,
			AvgPerJobUSD:       avgPerJobUSD(row.EarnedMicroUSD, row.Jobs),
			PromptTokens:       row.PromptTokens,
			CompletionTokens:   row.CompletionTokens,
			TotalTokens:        totalTokens,
			ModelsServed:       row.ModelsServed,
			NodeCount:          row.NodeCount,
			LastActiveAt:       row.LastActiveAt.UTC(),
			LastActiveRelative: humanizeDuration(generatedAt.Sub(row.LastActiveAt.UTC())),
		})
	}

	return Leaderboard{
		Scope:       query.Scope,
		Window:      query.Window,
		Limit:       query.Limit,
		Backend:     s.store.Backend(),
		GeneratedAt: generatedAt,
		Entries:     entries,
	}, nil
}

func ParseScope(raw string) (Scope, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", string(ScopeAccount):
		return ScopeAccount, nil
	case string(ScopeNode):
		return ScopeNode, nil
	default:
		return "", fmt.Errorf("unsupported scope %q", raw)
	}
}

func ParseWindow(raw string) (Window, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", string(Window7d):
		return Window7d, nil
	case string(Window24h):
		return Window24h, nil
	case string(Window30d):
		return Window30d, nil
	case string(WindowAll):
		return WindowAll, nil
	default:
		return "", fmt.Errorf("unsupported window %q", raw)
	}
}

func normalizeQuery(query Query) Query {
	if query.Scope == "" {
		query.Scope = ScopeAccount
	}
	if query.Window == "" {
		query.Window = Window7d
	}
	if query.Limit <= 0 {
		query.Limit = DefaultLimit
	}
	if query.Limit > MaxLimit {
		query.Limit = MaxLimit
	}
	return query
}

func validateQuery(query Query) error {
	if _, err := ParseScope(string(query.Scope)); err != nil {
		return err
	}
	if _, err := ParseWindow(string(query.Window)); err != nil {
		return err
	}
	if query.Limit <= 0 || query.Limit > MaxLimit {
		return fmt.Errorf("limit must be between 1 and %d", MaxLimit)
	}
	return nil
}

func cutoffForWindow(now time.Time, window Window) (time.Time, bool) {
	now = now.UTC()
	switch window {
	case Window24h:
		return now.Add(-24 * time.Hour), true
	case Window7d:
		return now.Add(-7 * 24 * time.Hour), true
	case Window30d:
		return now.Add(-30 * 24 * time.Hour), true
	case WindowAll:
		return time.Time{}, false
	default:
		return time.Time{}, false
	}
}

func formatUSD(microUSD int64) string {
	return fmt.Sprintf("%.6f", float64(microUSD)/1_000_000)
}

func avgPerJobUSD(totalMicroUSD, jobs int64) string {
	if jobs <= 0 {
		return "0.000000"
	}
	return fmt.Sprintf("%.6f", (float64(totalMicroUSD)/float64(jobs))/1_000_000)
}

func humanizeDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		minutes := int(d / time.Minute)
		return fmt.Sprintf("%dm ago", minutes)
	case d < 24*time.Hour:
		hours := int(d / time.Hour)
		return fmt.Sprintf("%dh ago", hours)
	default:
		days := int(d / (24 * time.Hour))
		return fmt.Sprintf("%dd ago", days)
	}
}

type providerSnapshot struct {
	AccountID   string
	LastSeen    time.Time
	TrustLevel  string
	MDAVerified bool
}

type earningEvent struct {
	AccountID        string
	ProviderID       string
	ProviderKey      string
	Model            string
	AmountMicroUSD   int64
	PromptTokens     int64
	CompletionTokens int64
	CreatedAt        time.Time
}

type MemoryStore struct {
	activeNodeWindow time.Duration
	providers        []providerSnapshot
	earnings         []earningEvent
	now              func() time.Time
}

func NewMemoryStore(activeNodeWindow time.Duration) *MemoryStore {
	return NewMemoryStoreWithClock(activeNodeWindow, time.Now)
}

func NewMemoryStoreWithClock(activeNodeWindow time.Duration, now func() time.Time) *MemoryStore {
	base := now().UTC()
	return &MemoryStore{
		activeNodeWindow: activeNodeWindow,
		now:              now,
		providers: []providerSnapshot{
			{AccountID: "acct-alpha", LastSeen: base.Add(-35 * time.Second), TrustLevel: "hardware", MDAVerified: true},
			{AccountID: "acct-alpha", LastSeen: base.Add(-50 * time.Second), TrustLevel: "hardware", MDAVerified: true},
			{AccountID: "acct-bravo", LastSeen: base.Add(-90 * time.Second), TrustLevel: "hardware", MDAVerified: true},
			{AccountID: "acct-charlie", LastSeen: base.Add(-3 * time.Minute), TrustLevel: "hardware", MDAVerified: false},
			{AccountID: "acct-delta", LastSeen: base.Add(-45 * time.Second), TrustLevel: "none", MDAVerified: false},
		},
		earnings: []earningEvent{
			{AccountID: "acct-alpha", ProviderID: "prov-a1", ProviderKey: "node-a1", Model: "mlx-community/gemma-4-26b-a4b-it-8bit", AmountMicroUSD: 5_400_000, PromptTokens: 14_000, CompletionTokens: 22_500, CreatedAt: base.Add(-2 * time.Hour)},
			{AccountID: "acct-alpha", ProviderID: "prov-a2", ProviderKey: "node-a2", Model: "qwen3.5-27b-claude-opus-8bit", AmountMicroUSD: 3_300_000, PromptTokens: 8_500, CompletionTokens: 15_200, CreatedAt: base.Add(-18 * time.Hour)},
			{AccountID: "acct-alpha", ProviderID: "prov-a1", ProviderKey: "node-a1", Model: "qwen3.5-27b-claude-opus-8bit", AmountMicroUSD: 8_900_000, PromptTokens: 19_500, CompletionTokens: 34_100, CreatedAt: base.Add(-4 * 24 * time.Hour)},
			{AccountID: "acct-bravo", ProviderID: "prov-b1", ProviderKey: "node-b1", Model: "mlx-community/Trinity-Mini-8bit", AmountMicroUSD: 2_100_000, PromptTokens: 6_200, CompletionTokens: 9_000, CreatedAt: base.Add(-3 * time.Hour)},
			{AccountID: "acct-bravo", ProviderID: "prov-b1", ProviderKey: "node-b1", Model: "mlx-community/Trinity-Mini-8bit", AmountMicroUSD: 2_900_000, PromptTokens: 7_800, CompletionTokens: 12_200, CreatedAt: base.Add(-26 * time.Hour)},
			{AccountID: "acct-charlie", ProviderID: "prov-c1", ProviderKey: "node-c1", Model: "mlx-community/Qwen2.5-7B-4bit", AmountMicroUSD: 6_500_000, PromptTokens: 15_200, CompletionTokens: 28_300, CreatedAt: base.Add(-6 * 24 * time.Hour)},
			{AccountID: "acct-delta", ProviderID: "prov-d1", ProviderKey: "node-d1", Model: "mlx-community/Gemma-4-27B-4bit", AmountMicroUSD: 1_800_000, PromptTokens: 4_100, CompletionTokens: 7_600, CreatedAt: base.Add(-12 * time.Hour)},
			{AccountID: "acct-echo", ProviderID: "prov-e1", ProviderKey: "node-e1", Model: "mlx-community/gemma-4-26b-a4b-it-8bit", AmountMicroUSD: 13_700_000, PromptTokens: 31_500, CompletionTokens: 48_000, CreatedAt: base.Add(-9 * 24 * time.Hour)},
		},
	}
}

func (m *MemoryStore) Backend() string {
	return "memory"
}

func (m *MemoryStore) Ping(context.Context) error {
	return nil
}

func (m *MemoryStore) Close() {}

func (m *MemoryStore) Overview(context.Context) (Overview, error) {
	now := m.now().UTC()
	var overview Overview
	accountSet := make(map[string]struct{})
	for _, provider := range m.providers {
		overview.RegisteredNodes++
		if provider.AccountID != "" {
			accountSet[provider.AccountID] = struct{}{}
		}
		if now.Sub(provider.LastSeen) <= m.activeNodeWindow {
			overview.ActiveNodes++
		}
		if provider.TrustLevel == "hardware" {
			overview.HardwareTrustedNodes++
		}
		if provider.MDAVerified {
			overview.MDAVerifiedNodes++
		}
	}
	overview.LinkedAccounts = int64(len(accountSet))

	cutoff24h := now.Add(-24 * time.Hour)
	for _, earning := range m.earnings {
		overview.TotalJobs++
		overview.TotalEarnedMicroUSD += earning.AmountMicroUSD
		if !earning.CreatedAt.Before(cutoff24h) {
			overview.Jobs24h++
			overview.Earned24hMicroUSD += earning.AmountMicroUSD
		}
	}

	return overview, nil
}

func (m *MemoryStore) EarningsLeaderboard(_ context.Context, query Query) ([]rawEntry, error) {
	now := m.now().UTC()
	cutoff, bounded := cutoffForWindow(now, query.Window)

	type aggregate struct {
		earnedMicroUSD   int64
		jobs             int64
		promptTokens     int64
		completionTokens int64
		models           map[string]struct{}
		nodes            map[string]struct{}
		lastActiveAt     time.Time
	}

	aggregates := make(map[string]*aggregate)
	for _, earning := range m.earnings {
		if bounded && earning.CreatedAt.Before(cutoff) {
			continue
		}

		var key string
		switch query.Scope {
		case ScopeAccount:
			if earning.AccountID == "" {
				continue
			}
			key = earning.AccountID
		case ScopeNode:
			key = stableNodeID(earning.ProviderKey, earning.ProviderID)
			if key == "" {
				continue
			}
		default:
			return nil, fmt.Errorf("unsupported scope %q", query.Scope)
		}

		agg := aggregates[key]
		if agg == nil {
			agg = &aggregate{
				models: make(map[string]struct{}),
				nodes:  make(map[string]struct{}),
			}
			aggregates[key] = agg
		}

		agg.earnedMicroUSD += earning.AmountMicroUSD
		agg.jobs++
		agg.promptTokens += earning.PromptTokens
		agg.completionTokens += earning.CompletionTokens
		agg.models[earning.Model] = struct{}{}
		agg.nodes[stableNodeID(earning.ProviderKey, earning.ProviderID)] = struct{}{}
		if earning.CreatedAt.After(agg.lastActiveAt) {
			agg.lastActiveAt = earning.CreatedAt
		}
	}

	rows := make([]rawEntry, 0, len(aggregates))
	for key, agg := range aggregates {
		rows = append(rows, rawEntry{
			StableID:         key,
			EarnedMicroUSD:   agg.earnedMicroUSD,
			Jobs:             agg.jobs,
			PromptTokens:     agg.promptTokens,
			CompletionTokens: agg.completionTokens,
			ModelsServed:     int64(len(agg.models)),
			NodeCount:        int64(len(agg.nodes)),
			LastActiveAt:     agg.lastActiveAt,
		})
	}

	sort.Slice(rows, func(i, j int) bool {
		if rows[i].EarnedMicroUSD != rows[j].EarnedMicroUSD {
			return rows[i].EarnedMicroUSD > rows[j].EarnedMicroUSD
		}
		if !rows[i].LastActiveAt.Equal(rows[j].LastActiveAt) {
			return rows[i].LastActiveAt.After(rows[j].LastActiveAt)
		}
		return rows[i].StableID < rows[j].StableID
	})

	if len(rows) > query.Limit {
		rows = rows[:query.Limit]
	}
	if query.Scope == ScopeNode {
		for i := range rows {
			rows[i].NodeCount = 1
		}
	}
	return rows, nil
}

type PostgresStore struct {
	pool             *pgxpool.Pool
	activeNodeWindow time.Duration
}

func NewPostgresStore(ctx context.Context, databaseURL string, activeNodeWindow time.Duration) (*PostgresStore, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("connect postgres: %w", err)
	}
	store := &PostgresStore{
		pool:             pool,
		activeNodeWindow: activeNodeWindow,
	}
	if err := store.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return store, nil
}

func (p *PostgresStore) Backend() string {
	return "postgres"
}

func (p *PostgresStore) Ping(ctx context.Context) error {
	var one int
	if err := p.pool.QueryRow(ctx, "SELECT 1").Scan(&one); err != nil {
		return fmt.Errorf("ping postgres: %w", err)
	}
	return nil
}

func (p *PostgresStore) Close() {
	p.pool.Close()
}

func (p *PostgresStore) Overview(ctx context.Context) (Overview, error) {
	cutoff := time.Now().UTC().Add(-p.activeNodeWindow)

	const query = `
WITH provider_stats AS (
	SELECT
		COUNT(*) AS registered_nodes,
		COUNT(*) FILTER (WHERE last_seen >= $1) AS active_nodes,
		COUNT(DISTINCT account_id) FILTER (WHERE account_id <> '') AS linked_accounts,
		COUNT(*) FILTER (WHERE trust_level = 'hardware') AS hardware_trusted_nodes,
		COUNT(*) FILTER (WHERE mda_verified) AS mda_verified_nodes
	FROM providers
),
earning_stats AS (
	SELECT
		COALESCE(SUM(amount_micro_usd), 0) AS total_earned_micro_usd,
		COUNT(*) AS total_jobs,
		COALESCE(SUM(amount_micro_usd) FILTER (WHERE created_at >= NOW() - INTERVAL '24 hours'), 0) AS earned_24h_micro_usd,
		COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '24 hours') AS jobs_24h
	FROM provider_earnings
)
SELECT
	provider_stats.registered_nodes,
	provider_stats.active_nodes,
	provider_stats.linked_accounts,
	provider_stats.hardware_trusted_nodes,
	provider_stats.mda_verified_nodes,
	earning_stats.total_earned_micro_usd,
	earning_stats.total_jobs,
	earning_stats.earned_24h_micro_usd,
	earning_stats.jobs_24h
FROM provider_stats, earning_stats`

	var overview Overview
	if err := p.pool.QueryRow(ctx, query, cutoff).Scan(
		&overview.RegisteredNodes,
		&overview.ActiveNodes,
		&overview.LinkedAccounts,
		&overview.HardwareTrustedNodes,
		&overview.MDAVerifiedNodes,
		&overview.TotalEarnedMicroUSD,
		&overview.TotalJobs,
		&overview.Earned24hMicroUSD,
		&overview.Jobs24h,
	); err != nil {
		return Overview{}, fmt.Errorf("query overview: %w", err)
	}

	return overview, nil
}

func (p *PostgresStore) EarningsLeaderboard(ctx context.Context, query Query) ([]rawEntry, error) {
	now := time.Now().UTC()
	cutoff, bounded := cutoffForWindow(now, query.Window)

	whereClauses := []string{}
	args := make([]any, 0, 2)

	switch query.Scope {
	case ScopeAccount:
		whereClauses = append(whereClauses, "account_id <> ''")
	case ScopeNode:
		whereClauses = append(whereClauses, "(provider_key <> '' OR provider_id <> '')")
	default:
		return nil, fmt.Errorf("unsupported scope %q", query.Scope)
	}

	if bounded {
		args = append(args, cutoff)
		whereClauses = append(whereClauses, "created_at >= $"+strconv.Itoa(len(args)))
	}

	args = append(args, query.Limit)
	limitPlaceholder := "$" + strconv.Itoa(len(args))
	whereSQL := ""
	if len(whereClauses) > 0 {
		whereSQL = "WHERE " + strings.Join(whereClauses, " AND ")
	}

	var sql string
	switch query.Scope {
	case ScopeAccount:
		sql = fmt.Sprintf(`
SELECT
	account_id AS stable_id,
	SUM(amount_micro_usd) AS earned_micro_usd,
	COUNT(*) AS jobs,
	COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
	COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
	COUNT(DISTINCT model) AS models_served,
	COUNT(DISTINCT CASE WHEN provider_key <> '' THEN provider_key ELSE provider_id END) AS node_count,
	MAX(created_at) AS last_active_at
FROM provider_earnings
%s
GROUP BY account_id
ORDER BY earned_micro_usd DESC, last_active_at DESC, stable_id ASC
LIMIT %s`, whereSQL, limitPlaceholder)
	case ScopeNode:
		sql = fmt.Sprintf(`
SELECT
	CASE WHEN provider_key <> '' THEN provider_key ELSE provider_id END AS stable_id,
	SUM(amount_micro_usd) AS earned_micro_usd,
	COUNT(*) AS jobs,
	COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
	COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
	COUNT(DISTINCT model) AS models_served,
	1 AS node_count,
	MAX(created_at) AS last_active_at
FROM provider_earnings
%s
GROUP BY CASE WHEN provider_key <> '' THEN provider_key ELSE provider_id END
ORDER BY earned_micro_usd DESC, last_active_at DESC, stable_id ASC
LIMIT %s`, whereSQL, limitPlaceholder)
	}

	rows, err := p.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("query earnings leaderboard: %w", err)
	}
	defer rows.Close()

	entries := make([]rawEntry, 0, query.Limit)
	for rows.Next() {
		var row rawEntry
		if err := rows.Scan(
			&row.StableID,
			&row.EarnedMicroUSD,
			&row.Jobs,
			&row.PromptTokens,
			&row.CompletionTokens,
			&row.ModelsServed,
			&row.NodeCount,
			&row.LastActiveAt,
		); err != nil {
			return nil, fmt.Errorf("scan earnings leaderboard: %w", err)
		}
		entries = append(entries, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate earnings leaderboard: %w", err)
	}

	return entries, nil
}

func stableNodeID(providerKey, providerID string) string {
	if providerKey != "" {
		return providerKey
	}
	return providerID
}
