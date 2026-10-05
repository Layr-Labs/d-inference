package payoutaudit

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	postgresstore "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Options struct {
	limit               int
	since               string
	refundID, requestID string
	amount              int64
}

func ParseOptions(args []string) (Options, error) {
	var o Options
	f := flag.NewFlagSet("payout-audit", flag.ContinueOnError)
	f.IntVar(&o.limit, "limit", 50, "maximum records per rail (1-200)")
	f.StringVar(&o.since, "since", time.Now().UTC().Add(-30*24*time.Hour).Format(time.RFC3339), "earliest timestamp for read-only audit")
	f.StringVar(&o.refundID, "apply-refund", "", "refund one verified rejected Connect withdrawal UUID")
	f.StringVar(&o.requestID, "verified-stripe-request", "", "operator-confirmed Stripe request proving rejection before transfer creation")
	f.Int64Var(&o.amount, "expected-amount-micro-usd", 0, "exact amount of the approved withdrawal")
	if err := f.Parse(args); err != nil {
		return o, err
	}
	if f.NArg() != 0 || o.limit < 1 || o.limit > 200 {
		return o, errors.New("invalid arguments or limit")
	}
	if _, err := time.Parse(time.RFC3339, o.since); err != nil {
		return o, errors.New("since must be RFC3339")
	}
	if o.refundID != "" {
		if _, err := uuid.Parse(o.refundID); err != nil {
			return o, errors.New("apply-refund requires an exact withdrawal UUID")
		}
		if !regexp.MustCompile(`^req_[A-Za-z0-9]+$`).MatchString(o.requestID) || o.amount <= 0 {
			return o, errors.New("apply-refund requires verified-stripe-request and a positive expected-amount-micro-usd")
		}
	} else if o.requestID != "" || o.amount != 0 {
		return o, errors.New("refund assertions require apply-refund")
	}
	return o, nil
}

func Run(ctx context.Context, args []string, out io.Writer) error {
	o, err := ParseOptions(args)
	if err != nil {
		return err
	}
	dsn := os.Getenv("EIGENINFERENCE_DATABASE_URL")
	if dsn == "" {
		return errors.New("EIGENINFERENCE_DATABASE_URL is required")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return errors.New("invalid database configuration")
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = "1000"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return errors.New("database connection failed")
	}
	defer pool.Close()
	if o.refundID != "" {
		return applyRefund(ctx, pool, o, out)
	}
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return errors.New("could not start read-only audit")
	}
	defer tx.Rollback(ctx)
	queries := []string{
		`SELECT json_build_object('rail','connect','id',id,'status',status,'amount_micro_usd',amount_micro_usd,'refunded',refunded,'transfer_id',transfer_id,'payout_id',payout_id,'sweep_payout_id',sweep_payout_id,'failure_reason',failure_reason,'created_at',created_at) FROM stripe_withdrawals WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		`SELECT json_build_object('rail','global','id',id,'status',status,'external_id',external_id,'amount_micro_usd',data->'amount_micro_usd','refunded',data->'refunded','failure_code',data->'failure_code','submitted_at',submitted_at) FROM global_payout_withdrawals WHERE status<>'quoted' AND submitted_at >= $1 ORDER BY submitted_at DESC LIMIT $2`,
	}
	for _, q := range queries {
		rows, err := tx.Query(ctx, q, o.since, o.limit)
		if err != nil {
			return errors.New("audit query failed; no changes made")
		}
		for rows.Next() {
			var b []byte
			if err := rows.Scan(&b); err != nil {
				rows.Close()
				return err
			}
			if _, err := fmt.Fprintln(out, string(b)); err != nil {
				rows.Close()
				return err
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return errors.New("audit timed out; narrow the window")
		}
	}
	return tx.Commit(ctx)
}

func applyRefund(ctx context.Context, pool *pgxpool.Pool, o Options, out io.Writer) error {
	var status, reason, transfer, payout, sweep string
	var amount int64
	var refunded bool
	err := pool.QueryRow(ctx, `SELECT status,failure_reason,transfer_id,payout_id,sweep_payout_id,amount_micro_usd,refunded FROM stripe_withdrawals WHERE id=$1`, o.refundID).Scan(&status, &reason, &transfer, &payout, &sweep, &amount, &refunded)
	if err != nil {
		return errors.New("could not read the exact approved withdrawal")
	}
	if amount != o.amount {
		return errors.New("expected amount does not match; no changes made")
	}
	if refunded {
		return json.NewEncoder(out).Encode(map[string]any{"id": o.refundID, "already_refunded": true})
	}
	if status != "failed" || transfer != "" || payout != "" || sweep != "" || !strings.HasPrefix(reason, "transfer_create_failed:") {
		return errors.New("row is not a rejected transfer; reconcile its Stripe outcome first")
	}
	// The operator verified the original request in Stripe. Compare the exact
	// observed row again when saving that assertion; never promote by age or ID absence.
	confirmed := store.StripeConfirmedRejectionPrefix + "operator verified " + o.requestID + "; " + reason
	r, err := pool.Exec(ctx, `UPDATE stripe_withdrawals SET failure_reason=$2,updated_at=NOW() WHERE id=$1 AND amount_micro_usd=$3 AND failure_reason=$4 AND status='failed' AND NOT refunded AND transfer_id='' AND payout_id='' AND sweep_payout_id=''`, o.refundID, confirmed, o.amount, reason)
	if err != nil || r.RowsAffected() != 1 {
		return errors.New("withdrawal changed; rerun audit before applying")
	}
	applied, err := postgresstore.StripeSettlementForMaintenance(pool).RefundRejectedStripeWithdrawal(o.refundID)
	if err != nil {
		return errors.New("refund not confirmed; durable verified rejection retained for retry")
	}
	return json.NewEncoder(out).Encode(map[string]any{"id": o.refundID, "refund_applied": applied})
}
