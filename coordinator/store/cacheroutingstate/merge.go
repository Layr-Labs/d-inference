package cacheroutingstate

// Later merges an incoming row into an existing one: the newer UpdatedAt wins
// every descriptive column and ExpiresAt never moves backwards, which makes a
// replayed or reordered batch idempotent. The Postgres ON CONFLICT clause
// mirrors this rule.
func Later(existing, incoming HolderRecord) HolderRecord {
	if incoming.UpdatedAt.Before(existing.UpdatedAt) {
		merged := existing
		if incoming.ExpiresAt.After(merged.ExpiresAt) {
			merged.ExpiresAt = incoming.ExpiresAt
		}
		return merged
	}
	merged := incoming
	if existing.ExpiresAt.After(merged.ExpiresAt) {
		merged.ExpiresAt = existing.ExpiresAt
	}
	return merged
}

// DedupeHolders keeps one row per (key, epoch) in a batch, merging with Later.
// PostgreSQL rejects a statement that touches the same conflict target twice.
func DedupeHolders(records []HolderRecord) []HolderRecord {
	seen := make(map[HolderKey]int, len(records))
	out := make([]HolderRecord, 0, len(records))
	for _, r := range records {
		if i, ok := seen[r.HolderKey()]; ok {
			out[i] = Later(out[i], r)
			continue
		}
		seen[r.HolderKey()] = len(out)
		out = append(out, r)
	}
	return out
}

// DedupeDemand keeps one row per key in a batch with its latest SeenAt.
func DedupeDemand(records []DemandRecord) []DemandRecord {
	seen := make(map[string]int, len(records))
	out := make([]DemandRecord, 0, len(records))
	for _, r := range records {
		if i, ok := seen[r.Key]; ok {
			if r.SeenAt.After(out[i].SeenAt) {
				out[i].SeenAt = r.SeenAt
			}
			continue
		}
		seen[r.Key] = len(out)
		out = append(out, r)
	}
	return out
}
