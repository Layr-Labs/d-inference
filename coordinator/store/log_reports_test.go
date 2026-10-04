package store

import "testing"

func TestLogReportRoundTripBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("acct")
			data := []byte("provider log line 1\nprovider log line 2\n")
			id, err := s.StoreLogReport(account, data)
			if err != nil || id <= 0 {
				t.Fatalf("StoreLogReport = %d, %v", id, err)
			}
			data[0] = 'X' // the store must keep its own copy

			got, err := s.GetLogReport(id)
			if err != nil {
				t.Fatalf("GetLogReport: %v", err)
			}
			if got.ID != id || got.AccountID != account || string(got.LogData) != "provider log line 1\nprovider log line 2\n" ||
				got.LogSizeBytes != int64(len(got.LogData)) || got.CreatedAt.IsZero() {
				t.Fatalf("report = %+v", got)
			}

			second, err := s.StoreLogReport(account, []byte("next"))
			if err != nil || second == id {
				t.Fatalf("second report ID = %d, %v; want a new ID", second, err)
			}
			if _, err := s.GetLogReport(second + 1_000_000); err == nil {
				t.Fatal("unknown report ID returned a report")
			}
		})
	}
}
