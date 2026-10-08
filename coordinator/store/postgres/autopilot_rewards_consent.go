package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ObserveAutopilotConsent(ctx context.Context, consent earningsfloor.Consent) (earningsfloor.Enrollment, error) {
	consent.At = consent.At.UTC().Truncate(time.Microsecond)
	if consent.SessionID == "" || consent.AccountID == "" || consent.At.IsZero() || (consent.OptedIn && !consent.Supported) {
		return earningsfloor.Enrollment{}, earningsfloor.ErrIdentity
	}
	if consent.At.After(s.now()) {
		return earningsfloor.Enrollment{}, errors.New("future autopilot consent")
	}
	machineID, err := s.journalAutopilotConsent(ctx, consent)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	// The journal commits first, even when binding or baseline calculation fails.
	// A reconnect can therefore recover the original first-positive instant.
	return s.autopilotRewardEnrollment(ctx, machineID)
}

func (s *PostgresStore) journalAutopilotConsent(ctx context.Context, consent earningsfloor.Consent) (string, error) {
	tx, err := s.beginAutopilotRewardWrite(ctx, consent.AccountID)
	if err != nil {
		return "", err
	}
	defer rollbackErasureTx(tx)
	if err := checkPersonalSession(ctx, tx, consent.SessionID, consent.AccountID); err != nil {
		return "", err
	}
	var owners []string
	var boundID *string
	err = tx.QueryRow(ctx, `SELECT
	 ARRAY(SELECT account_id FROM provider_sessions WHERE session_id=$1 AND account_id<>''
	 UNION SELECT account_id FROM providers WHERE id=$1 AND account_id<>''
	 UNION SELECT account_id FROM darkbloom_machine_sessions WHERE session_id=$1 AND account_id<>''
	 UNION SELECT account_id FROM autopilot_reward_consents WHERE session_id=$1),
	 (SELECT machine_id FROM darkbloom_machine_sessions WHERE session_id=$1)`, consent.SessionID).Scan(&owners, &boundID)
	if err != nil {
		return "", err
	}
	for _, owner := range owners {
		if owner != consent.AccountID {
			return "", earningsfloor.ErrIdentity
		}
	}
	var machine autopilotRewardMachine
	identityErr := earningsfloor.ErrIdentity
	if boundID != nil {
		machine, identityErr = resolveAutopilotRewardMachine(ctx, tx, *boundID)
		if identityErr != nil && !errors.Is(identityErr, earningsfloor.ErrIdentity) {
			return "", identityErr
		}
		if identityErr == nil && machine.account != consent.AccountID {
			return "", earningsfloor.ErrIdentity
		}
	}
	var journalMachine *string
	if identityErr == nil {
		journalMachine = &machine.id
		if err := bindAutopilotRewardConsents(ctx, tx, machine); err != nil {
			return "", err
		}
	}
	// A different session can commit a newer declaration first. Preserve this
	// session's earlier evidence; timestamp-ordered projections prevent it from
	// regressing current consent without losing a first-ever positive instant.
	var at, observedAt time.Time
	var optedIn, supported bool
	err = tx.QueryRow(ctx, `SELECT at,last_observed_at,opted_in,supported FROM autopilot_reward_consents
	 WHERE session_id=$1 ORDER BY last_observed_at DESC LIMIT 1`, consent.SessionID).
		Scan(&at, &observedAt, &optedIn, &supported)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	if errors.Is(err, pgx.ErrNoRows) || consent.At.After(observedAt) {
		if err == nil && optedIn == consent.OptedIn && supported == consent.Supported && floorpolicy.Day(at).Equal(floorpolicy.Day(consent.At)) {
			_, err = tx.Exec(ctx, `UPDATE autopilot_reward_consents SET last_observed_at=$3 WHERE session_id=$1 AND at=$2`, consent.SessionID, at, consent.At)
		} else {
			_, err = tx.Exec(ctx, `INSERT INTO autopilot_reward_consents(machine_id,at,last_observed_at,account_id,session_id,opted_in,supported)
			 VALUES($1,$2,$2,$3,$4,$5,$6)`, journalMachine, consent.At, consent.AccountID, consent.SessionID, consent.OptedIn, consent.Supported)
		}
		if err != nil {
			return "", err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return machine.id, identityErr
}

func bindAutopilotRewardConsents(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine) error {
	_, err := tx.Exec(ctx, `UPDATE autopilot_reward_consents c SET machine_id=s.machine_id
	 FROM darkbloom_machine_sessions s WHERE c.machine_id IS NULL AND c.session_id=s.session_id
	 AND c.account_id=s.account_id AND s.machine_id=ANY($1::text[])`, machine.ancestors)
	return err
}

// Each watermark is confined to its row's UTC day. A merge can therefore use
// the last durable declaration before day end without rewriting earlier days.
func autopilotConsentAt(ctx context.Context, tx pgx.Tx, ancestors []string, before *time.Time) (bool, time.Time, error) {
	var observedAt *time.Time
	var allIn, anyIn, allSupported, anySupported bool
	err := tx.QueryRow(ctx, `WITH declarations AS (
	 SELECT last_observed_at,opted_in,supported FROM autopilot_reward_consents
	 WHERE machine_id=ANY($1::text[]) AND ($2::timestamptz IS NULL OR last_observed_at<$2)
	), latest AS (SELECT * FROM declarations WHERE last_observed_at=(SELECT max(last_observed_at) FROM declarations))
	 SELECT max(last_observed_at),COALESCE(bool_and(opted_in),false),COALESCE(bool_or(opted_in),false),
	 COALESCE(bool_and(supported),false),COALESCE(bool_or(supported),false) FROM latest`, ancestors, before).
		Scan(&observedAt, &allIn, &anyIn, &allSupported, &anySupported)
	if err != nil {
		return false, time.Time{}, err
	}
	if allIn != anyIn || allSupported != anySupported {
		return false, time.Time{}, earningsfloor.ErrIdentity
	}
	if observedAt == nil {
		return false, time.Time{}, nil
	}
	return allIn && allSupported, observedAt.UTC(), nil
}
