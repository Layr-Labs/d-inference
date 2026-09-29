package postgres_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLeaderboardScanFailureDoesNotReturnPartialRanking(t *testing.T) {
	s := testPostgresStore(t)
	// The isolated database has three valid jobs ahead of a two-job account
	// whose earnings sum cannot be represented by the public int64 contract.
	_, err := s.pool.Exec(context.Background(),
		`INSERT INTO provider_earnings(account_id,provider_key,provider_id,job_id,model,amount_micro_usd,prompt_tokens,completion_tokens) VALUES
		('good','key','provider','good1','work',1,1,1),
		('good','key','provider','good2','work',1,1,1),
		('good','key','provider','good3','work',1,1,1),
		('overflow','key','provider','overflow1','work',9223372036854775807,1,1),
		('overflow','key','provider','overflow2','work',9223372036854775807,1,1)`)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := s.Leaderboard(store.LeaderboardJobs, time.Time{}, 50)
	if err == nil || rows != nil {
		t.Fatalf("overflow after a valid first row returned partial ranking=%v error=%v", rows, err)
	}
}
