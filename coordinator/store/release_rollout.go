package store

import (
	"context"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// RolloutStage is a frozen provider-fleet cohort boundary.
type RolloutStage string

const (
	RolloutStageCanary RolloutStage = "canary"
	RolloutStage1      RolloutStage = "1"
	RolloutStage5      RolloutStage = "5"
	RolloutStage25     RolloutStage = "25"
	RolloutStage50     RolloutStage = "50"
	RolloutStage100    RolloutStage = "100"
)

var rolloutStages = [...]RolloutStage{
	RolloutStageCanary, RolloutStage1, RolloutStage5,
	RolloutStage25, RolloutStage50, RolloutStage100,
}

var (
	ErrRolloutNotFound = errors.New("release rollout not found")
	ErrRolloutConflict = errors.New("release rollout revision conflict")
	ErrRolloutInvalid  = errors.New("invalid release rollout transition")
)

// ReleaseRolloutPolicy is the authoritative, durable rollout state for one
// platform. Revision and DesiredGeneration increase on every transition.
type ReleaseRolloutPolicy struct {
	Platform           string       `json:"platform"`
	Backend            string       `json:"backend,omitempty"`
	TargetVersion      string       `json:"target_version"`
	PreviousVersion    string       `json:"previous_version,omitempty"`
	Stage              RolloutStage `json:"stage"`
	CanarySEIdentities []string     `json:"canary_se_identities,omitempty"`
	Paused             bool         `json:"paused"`
	PauseReason        string       `json:"pause_reason,omitempty"`
	DesiredGeneration  uint64       `json:"desired_generation"`
	Revision           uint64       `json:"revision"`
	CreatedAt          time.Time    `json:"created_at"`
	UpdatedAt          time.Time    `json:"updated_at"`
}

// ReleaseRolloutTransition is an immutable audit row written atomically with
// its policy mutation.
type ReleaseRolloutTransition struct {
	ID               int64        `json:"id"`
	Platform         string       `json:"platform"`
	TargetVersion    string       `json:"target_version"`
	Action           string       `json:"action"`
	FromStage        RolloutStage `json:"from_stage"`
	ToStage          RolloutStage `json:"to_stage"`
	Reason           string       `json:"reason,omitempty"`
	Actor            string       `json:"actor"`
	ExpectedRevision uint64       `json:"expected_revision"`
	ResultRevision   uint64       `json:"result_revision"`
	CreatedAt        time.Time    `json:"created_at"`
}

type StartReleaseRolloutRequest struct {
	Platform           string
	TargetVersion      string
	CanarySEIdentities []string
	ExpectedRevision   uint64
	Actor              string
}

type ReleaseRolloutTransitionRequest struct {
	Platform         string
	ExpectedRevision uint64
	Action           string // promote, pause, resume, automatic_pause
	Stage            RolloutStage
	Reason           string
	Actor            string
}

func RolloutStagePercent(stage RolloutStage) (int, bool) {
	switch stage {
	case RolloutStageCanary:
		return 0, true
	case RolloutStage1:
		return 1, true
	case RolloutStage5:
		return 5, true
	case RolloutStage25:
		return 25, true
	case RolloutStage50:
		return 50, true
	case RolloutStage100:
		return 100, true
	default:
		return 0, false
	}
}

func rolloutStageIndex(stage RolloutStage) int {
	for i, candidate := range rolloutStages {
		if candidate == stage {
			return i
		}
	}
	return -1
}

func normalizeCanaryIdentities(values []string) ([]string, error) {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return nil, fmt.Errorf("%w: invalid canary Secure-Enclave identity", ErrRolloutInvalid)
		}
		x, y := elliptic.Unmarshal(elliptic.P256(), decoded)
		if x == nil || y == nil {
			return nil, fmt.Errorf("%w: invalid canary Secure-Enclave identity", ErrRolloutInvalid)
		}
		value = base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), x, y))
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%w: at least one canary Secure-Enclave identity is required", ErrRolloutInvalid)
	}
	return out, nil
}

func cloneRollout(policy *ReleaseRolloutPolicy) *ReleaseRolloutPolicy {
	if policy == nil {
		return nil
	}
	copy := *policy
	copy.CanarySEIdentities = append([]string(nil), policy.CanarySEIdentities...)
	return &copy
}

func activeReleaseForRollout(releases map[string]*Release, version, platform string) (*Release, error) {
	release := releases[releaseKey(version, platform)]
	if release == nil || !release.Active {
		return nil, fmt.Errorf("%w: target release is not active", ErrRolloutInvalid)
	}
	copy := *release
	return &copy, nil
}

func previousActiveRelease(releases map[string]*Release, target *Release) *Release {
	var previous *Release
	for _, candidate := range releases {
		if !candidate.Active || candidate.Platform != target.Platform || candidate.Version == target.Version ||
			!releaseVersionGreater(target.Version, candidate.Version) {
			continue
		}
		if previous == nil || releaseVersionGreater(candidate.Version, previous.Version) {
			copy := *candidate
			previous = &copy
		}
	}
	return previous
}

func mapRolloutCASErr(err error) error {
	var postgresError *pgconn.PgError
	if errors.As(err, &postgresError) && postgresError.Code == "23505" {
		return ErrRolloutConflict
	}
	return err
}

func validateNewRollout(current *ReleaseRolloutPolicy, target *Release, expected uint64) error {
	if current == nil {
		if expected != 0 {
			return ErrRolloutConflict
		}
		return nil
	}
	if current.Revision != expected {
		return ErrRolloutConflict
	}
	if current.Stage != RolloutStage100 || current.Paused {
		return fmt.Errorf("%w: current rollout must be active at stage 100", ErrRolloutInvalid)
	}
	if !releaseVersionGreater(target.Version, current.TargetVersion) {
		return fmt.Errorf("%w: downgrade or repeated target release", ErrRolloutInvalid)
	}
	return nil
}

func applyRolloutTransition(current *ReleaseRolloutPolicy, request ReleaseRolloutTransitionRequest, now time.Time) (*ReleaseRolloutPolicy, ReleaseRolloutTransition, error) {
	if current == nil {
		return nil, ReleaseRolloutTransition{}, ErrRolloutNotFound
	}
	if request.ExpectedRevision != current.Revision {
		return nil, ReleaseRolloutTransition{}, ErrRolloutConflict
	}
	next := cloneRollout(current)
	action := strings.TrimSpace(request.Action)
	switch action {
	case "promote":
		if current.Paused {
			return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: paused rollout cannot promote", ErrRolloutInvalid)
		}
		from, to := rolloutStageIndex(current.Stage), rolloutStageIndex(request.Stage)
		if from < 0 || to != from+1 {
			return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: promotion must advance exactly one stage", ErrRolloutInvalid)
		}
		next.Stage = request.Stage
	case "pause", "automatic_pause":
		if current.Paused {
			return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: rollout is already paused", ErrRolloutInvalid)
		}
		if strings.TrimSpace(request.Reason) == "" {
			return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: pause reason is required", ErrRolloutInvalid)
		}
		next.Paused = true
		next.PauseReason = strings.TrimSpace(request.Reason)
	case "resume":
		if !current.Paused {
			return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: rollout is not paused", ErrRolloutInvalid)
		}
		next.Paused = false
		next.PauseReason = ""
	default:
		return nil, ReleaseRolloutTransition{}, fmt.Errorf("%w: unknown action", ErrRolloutInvalid)
	}
	next.Revision++
	next.UpdatedAt = now
	audit := ReleaseRolloutTransition{
		Platform: current.Platform, TargetVersion: current.TargetVersion,
		Action: action, FromStage: current.Stage, ToStage: next.Stage,
		Reason: strings.TrimSpace(request.Reason), Actor: strings.TrimSpace(request.Actor),
		ExpectedRevision: request.ExpectedRevision, ResultRevision: next.Revision,
		CreatedAt: now,
	}
	if audit.Actor == "" {
		audit.Actor = "system"
	}
	return next, audit, nil
}

func (s *MemoryStore) GetReleaseRollout(_ context.Context, platform string) (*ReleaseRolloutPolicy, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	policy := s.releaseRollouts[strings.TrimSpace(platform)]
	if policy == nil {
		return nil, ErrRolloutNotFound
	}
	return cloneRollout(policy), nil
}

func (s *MemoryStore) StartReleaseRollout(_ context.Context, request StartReleaseRolloutRequest) (*ReleaseRolloutPolicy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	request.Platform = strings.TrimSpace(request.Platform)
	target, err := activeReleaseForRollout(s.releases, strings.TrimSpace(request.TargetVersion), request.Platform)
	if err != nil {
		return nil, err
	}
	current := s.releaseRollouts[request.Platform]
	if err := validateNewRollout(current, target, request.ExpectedRevision); err != nil {
		return nil, err
	}
	canaries, err := normalizeCanaryIdentities(request.CanarySEIdentities)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	generation, revision := uint64(1), uint64(1)
	if current != nil {
		generation = current.DesiredGeneration + 1
		revision = current.Revision + 1
	}
	previousVersion := ""
	if current != nil {
		previousVersion = current.TargetVersion
	} else if previous := previousActiveRelease(s.releases, target); previous != nil {
		previousVersion = previous.Version
	}
	policy := &ReleaseRolloutPolicy{
		Platform: request.Platform, Backend: target.Backend, TargetVersion: target.Version,
		PreviousVersion: previousVersion, Stage: RolloutStageCanary,
		CanarySEIdentities: canaries, DesiredGeneration: generation,
		Revision: revision, CreatedAt: now, UpdatedAt: now,
	}
	s.releaseRollouts[request.Platform] = policy
	s.releaseRolloutTransitionSeq++
	actor := strings.TrimSpace(request.Actor)
	if actor == "" {
		actor = "system"
	}
	s.releaseRolloutTransitions = append(s.releaseRolloutTransitions, ReleaseRolloutTransition{
		ID: s.releaseRolloutTransitionSeq, Platform: policy.Platform, TargetVersion: policy.TargetVersion,
		Action: "start", ToStage: RolloutStageCanary, Actor: actor,
		ExpectedRevision: request.ExpectedRevision, ResultRevision: revision, CreatedAt: now,
	})
	return cloneRollout(policy), nil
}

func (s *MemoryStore) TransitionReleaseRollout(_ context.Context, request ReleaseRolloutTransitionRequest) (*ReleaseRolloutPolicy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	platform := strings.TrimSpace(request.Platform)
	current := s.releaseRollouts[platform]
	if current != nil {
		if _, err := activeReleaseForRollout(s.releases, current.TargetVersion, platform); err != nil {
			return nil, err
		}
		if current.Stage != RolloutStage100 && current.PreviousVersion != "" {
			if _, err := activeReleaseForRollout(s.releases, current.PreviousVersion, platform); err != nil {
				return nil, fmt.Errorf("%w: previous release is not active", ErrRolloutInvalid)
			}
		}
	}
	next, audit, err := applyRolloutTransition(current, request, time.Now().UTC())
	if err != nil {
		return nil, err
	}
	s.releaseRolloutTransitionSeq++
	audit.ID = s.releaseRolloutTransitionSeq
	s.releaseRollouts[platform] = next
	s.releaseRolloutTransitions = append(s.releaseRolloutTransitions, audit)
	return cloneRollout(next), nil
}

func (s *MemoryStore) ListReleaseRolloutTransitions(_ context.Context, platform string) ([]ReleaseRolloutTransition, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]ReleaseRolloutTransition, 0)
	for _, transition := range s.releaseRolloutTransitions {
		if platform == "" || transition.Platform == platform {
			out = append(out, transition)
		}
	}
	return out, nil
}

func scanReleaseRollout(row pgx.Row) (*ReleaseRolloutPolicy, error) {
	var policy ReleaseRolloutPolicy
	var canaries []byte
	var revision, generation int64
	err := row.Scan(&policy.Platform, &policy.Backend, &policy.TargetVersion, &policy.PreviousVersion,
		&policy.Stage, &canaries, &policy.Paused, &policy.PauseReason, &generation, &revision,
		&policy.CreatedAt, &policy.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrRolloutNotFound
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(canaries, &policy.CanarySEIdentities); err != nil {
		return nil, err
	}
	policy.DesiredGeneration = uint64(generation)
	policy.Revision = uint64(revision)
	return &policy, nil
}

const rolloutPolicyColumns = `platform, backend, target_version, previous_version, stage,
	canary_se_identities, paused, pause_reason, desired_generation, revision, created_at, updated_at`

func (s *PostgresStore) GetReleaseRollout(ctx context.Context, platform string) (*ReleaseRolloutPolicy, error) {
	return scanReleaseRollout(s.pool.QueryRow(ctx,
		`SELECT `+rolloutPolicyColumns+` FROM release_rollout_policies WHERE platform = $1`, strings.TrimSpace(platform)))
}

func (s *PostgresStore) StartReleaseRollout(ctx context.Context, request StartReleaseRolloutRequest) (*ReleaseRolloutPolicy, error) {
	request.Platform = strings.TrimSpace(request.Platform)
	request.TargetVersion = strings.TrimSpace(request.TargetVersion)
	canaries, err := normalizeCanaryIdentities(request.CanarySEIdentities)
	if err != nil {
		return nil, err
	}
	canaryJSON, _ := json.Marshal(canaries)
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var target Release
	err = tx.QueryRow(ctx, `SELECT version, platform, backend, created_at FROM releases WHERE version=$1 AND platform=$2 AND active=TRUE FOR UPDATE`, request.TargetVersion, request.Platform).
		Scan(&target.Version, &target.Platform, &target.Backend, &target.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%w: target release is not active", ErrRolloutInvalid)
	}
	if err != nil {
		return nil, err
	}
	current, currentErr := scanReleaseRollout(tx.QueryRow(ctx,
		`SELECT `+rolloutPolicyColumns+` FROM release_rollout_policies WHERE platform=$1 FOR UPDATE`, request.Platform))
	if currentErr != nil && !errors.Is(currentErr, ErrRolloutNotFound) {
		return nil, currentErr
	}
	if errors.Is(currentErr, ErrRolloutNotFound) {
		current = nil
	}
	if err := validateNewRollout(current, &target, request.ExpectedRevision); err != nil {
		return nil, err
	}
	previous := ""
	if current != nil {
		previous = current.TargetVersion
	} else {
		// The first policy adopts the highest active lower SemVer as its baseline.
		rows, err := tx.Query(ctx, `SELECT version FROM releases WHERE platform=$1 AND active=TRUE AND version<>$2`, request.Platform, request.TargetVersion)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var candidate string
			if err := rows.Scan(&candidate); err != nil {
				rows.Close()
				return nil, err
			}
			if releaseVersionGreater(target.Version, candidate) &&
				(previous == "" || releaseVersionGreater(candidate, previous)) {
				previous = candidate
			}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
	}
	generation, revision := uint64(1), uint64(1)
	if current != nil {
		generation, revision = current.DesiredGeneration+1, current.Revision+1
	}
	now := time.Now().UTC()
	policy := &ReleaseRolloutPolicy{Platform: request.Platform, Backend: target.Backend,
		TargetVersion: target.Version, PreviousVersion: previous, Stage: RolloutStageCanary,
		CanarySEIdentities: canaries, DesiredGeneration: generation, Revision: revision,
		CreatedAt: now, UpdatedAt: now}
	_, err = tx.Exec(ctx, `INSERT INTO release_rollout_policies
		(platform, backend, target_version, previous_version, stage, canary_se_identities, paused, pause_reason, desired_generation, revision, created_at, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,FALSE,'',$7,$8,$9,$9)
		ON CONFLICT (platform) DO UPDATE SET backend=$2,target_version=$3,previous_version=$4,stage=$5,
		canary_se_identities=$6,paused=FALSE,pause_reason='',desired_generation=$7,revision=$8,created_at=$9,updated_at=$9`,
		policy.Platform, policy.Backend, policy.TargetVersion, policy.PreviousVersion, policy.Stage,
		canaryJSON, int64(generation), int64(revision), now)
	if err != nil {
		return nil, err
	}
	actor := strings.TrimSpace(request.Actor)
	if actor == "" {
		actor = "system"
	}
	_, err = tx.Exec(ctx, `INSERT INTO release_rollout_transitions
		(platform,target_version,action,from_stage,to_stage,reason,actor,expected_revision,result_revision,created_at)
		VALUES ($1,$2,'start','',$3,'',$4,$5,$6,$7)`, policy.Platform, policy.TargetVersion,
		policy.Stage, actor, int64(request.ExpectedRevision), int64(revision), now)
	if err != nil {
		return nil, mapRolloutCASErr(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, mapRolloutCASErr(err)
	}
	return policy, nil
}

func (s *PostgresStore) TransitionReleaseRollout(ctx context.Context, request ReleaseRolloutTransitionRequest) (*ReleaseRolloutPolicy, error) {
	request.Platform = strings.TrimSpace(request.Platform)
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	current, err := scanReleaseRollout(tx.QueryRow(ctx,
		`SELECT `+rolloutPolicyColumns+` FROM release_rollout_policies WHERE platform=$1 FOR UPDATE`, request.Platform))
	if err != nil {
		return nil, err
	}
	var active bool
	if err := tx.QueryRow(ctx, `SELECT active FROM releases WHERE version=$1 AND platform=$2`, current.TargetVersion, current.Platform).Scan(&active); err != nil || !active {
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		return nil, fmt.Errorf("%w: target release is not active", ErrRolloutInvalid)
	}
	if current.Stage != RolloutStage100 && current.PreviousVersion != "" {
		if err := tx.QueryRow(ctx,
			`SELECT active FROM releases WHERE version=$1 AND platform=$2`,
			current.PreviousVersion, current.Platform).Scan(&active); err != nil || !active {
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
			return nil, fmt.Errorf("%w: previous release is not active", ErrRolloutInvalid)
		}
	}
	next, audit, err := applyRolloutTransition(current, request, time.Now().UTC())
	if err != nil {
		return nil, err
	}
	command, err := tx.Exec(ctx, `UPDATE release_rollout_policies SET stage=$1,paused=$2,pause_reason=$3,
		desired_generation=$4,revision=$5,updated_at=$6 WHERE platform=$7 AND revision=$8`,
		next.Stage, next.Paused, next.PauseReason, int64(next.DesiredGeneration), int64(next.Revision),
		next.UpdatedAt, next.Platform, int64(request.ExpectedRevision))
	if err != nil {
		return nil, err
	}
	if command.RowsAffected() != 1 {
		return nil, ErrRolloutConflict
	}
	_, err = tx.Exec(ctx, `INSERT INTO release_rollout_transitions
		(platform,target_version,action,from_stage,to_stage,reason,actor,expected_revision,result_revision,created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, audit.Platform, audit.TargetVersion,
		audit.Action, audit.FromStage, audit.ToStage, audit.Reason, audit.Actor,
		int64(audit.ExpectedRevision), int64(audit.ResultRevision), audit.CreatedAt)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return next, nil
}

func (s *PostgresStore) ListReleaseRolloutTransitions(ctx context.Context, platform string) ([]ReleaseRolloutTransition, error) {
	rows, err := s.pool.Query(ctx, `SELECT id,platform,target_version,action,from_stage,to_stage,reason,actor,
		expected_revision,result_revision,created_at FROM release_rollout_transitions
		WHERE ($1='' OR platform=$1) ORDER BY id`, strings.TrimSpace(platform))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ReleaseRolloutTransition, 0)
	for rows.Next() {
		var transition ReleaseRolloutTransition
		var expected, result int64
		if err := rows.Scan(&transition.ID, &transition.Platform, &transition.TargetVersion,
			&transition.Action, &transition.FromStage, &transition.ToStage, &transition.Reason,
			&transition.Actor, &expected, &result, &transition.CreatedAt); err != nil {
			return nil, err
		}
		transition.ExpectedRevision, transition.ResultRevision = uint64(expected), uint64(result)
		out = append(out, transition)
	}
	return out, rows.Err()
}
