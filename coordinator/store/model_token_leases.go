package store

import (
	"context"
	"time"
)

func (s *MemoryStore) RenewModelTokenReservations(ids []string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range ids {
		if r, ok := s.modelTokenReservations[id]; ok && r.State == "reserved" {
			r.TouchedAt = now
			s.modelTokenReservations[id] = r
		}
	}
	return nil
}

func (s *MemoryStore) ReleaseStaleModelTokenReservations(before time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for id := range s.modelTokenReservations {
		if count >= 100 {
			return count, nil
		}
		released, err := s.releaseModelTokenLocked(id, before)
		if err != nil {
			return count, err
		}
		if released {
			count++
		}
	}
	return count, nil
}

func (s *PostgresStore) RenewModelTokenReservations(ids []string, now time.Time) error {
	if len(ids) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx, `UPDATE model_token_reservations SET touched_at=$2 WHERE id=ANY($1::text[]) AND state='reserved'`, ids, now)
	return err
}

func (s *PostgresStore) ReleaseStaleModelTokenReservations(before time.Time) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT id FROM model_token_reservations WHERE state='reserved' AND touched_at<$1 ORDER BY touched_at LIMIT 100`, before)
	if err != nil {
		return 0, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	count := 0
	for _, id := range ids {
		// Re-check the lease under the reservation lock: a heartbeat may have
		// renewed it since the index scan, and a terminal may have settled it.
		released, err := s.releaseModelTokenBefore(id, before)
		if err != nil {
			return count, err
		}
		if released {
			count++
		}
	}
	return count, nil
}
