package registry

const (
	backupUsed uint32 = 1 << iota
	backupWon
)

// MarkBackupUsed records that this attempt participated in a speculative race.
// It cannot clear a concurrently published winner.
func (pr *PendingRequest) MarkBackupUsed() {
	if pr != nil {
		pr.speculativeBackup.Or(backupUsed)
	}
}

// MarkBackupWon records the serving backup. Winning also implies participation,
// so completion can never observe a winner without a backup having been used.
func (pr *PendingRequest) MarkBackupWon() {
	if pr != nil {
		pr.speculativeBackup.Or(backupUsed | backupWon)
	}
}

// BackupState returns one coherent snapshot while dispatch and completion race.
func (pr *PendingRequest) BackupState() (used, won bool) {
	if pr == nil {
		return false, false
	}
	state := pr.speculativeBackup.Load()
	return state&backupUsed != 0, state&backupWon != 0
}
