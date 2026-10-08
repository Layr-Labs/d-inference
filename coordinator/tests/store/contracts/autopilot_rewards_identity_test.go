package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsUnboundConsentSurvivesBinding(t *testing.T) {
	for _, provisional := range []bool{false, true} {
		name := "unbound"
		if provisional {
			name = "provisional"
		}
		t.Run(name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				if provisional {
					f.observe(t, store.MachineObservation{SessionID: "lost", AccountID: "owner", At: f.start})
				}
				for _, consent := range []earningsfloor.Consent{
					{SessionID: "lost", AccountID: "owner", Supported: true, At: f.start},
					{SessionID: "lost", AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn},
					{SessionID: "lost", AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn.Add(time.Hour)},
					{SessionID: "lost", AccountID: "owner", Supported: true, At: f.optIn.Add(2 * time.Hour)},
				} {
					got, err := f.rewards.ObserveAutopilotConsent(t.Context(), consent)
					if !errors.Is(err, earningsfloor.ErrIdentity) || got.MachineID != "" {
						t.Fatalf("unverified declaration enrolled a machine: %+v, %v", got, err)
					}
					if rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100); err != nil || len(rows) != 0 {
						t.Fatalf("unverified declaration appeared in enrollment list: %+v, %v", rows, err)
					}
				}
				f.earning(t, "lost", "owner", 70, f.optIn.Add(-time.Hour))
				// The original connection is gone; no declaration is retried after
				// the delayed inventory write. Listing must bind the durable journal.
				machine := f.observe(t, store.MachineObservation{SessionID: "lost", AccountID: "owner", SEKey: "se", Disconnected: true, At: f.optIn.Add(3 * time.Hour)})
				got := readAutopilotRewardEnrollment(t, f, machine.ID)
				if !got.BaselineKnown || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) || !got.FirstObservedAt.Equal(f.optIn) || got.SevenDayEarningsMicroUSD != 70 || got.OptedIn || !got.ObservedAt.Equal(f.optIn.Add(2*time.Hour)) {
					t.Fatalf("lazy binding lost the original declaration history: %+v", got)
				}
				if reconnect := f.observe(t, store.MachineObservation{SessionID: "reconnect", AccountID: "owner", SEKey: "se", At: f.optIn.Add(4 * time.Hour)}); reconnect.ID != machine.ID {
					t.Fatal("reconnect did not resolve the journal's canonical machine")
				}
				got = f.consent(t, "reconnect", "owner", true, f.optIn.Add(4*time.Hour))
				if got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) || got.SevenDayEarningsMicroUSD != 70 || !got.OptedIn {
					t.Fatalf("reconnect replaced first-ever opt-in with retry time: %+v", got)
				}
			})
		})
	}
}

func TestAutopilotRewardsImportedSessionKeepsPreTrackingHistoryUnknown(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "current", AccountID: "owner", SEKey: "shared-se", At: f.start})
		firstSeen := f.start.Add(-48 * time.Hour)
		imported := f.observe(t, store.MachineObservation{SessionID: "historical", AccountID: "owner", SEKey: "shared-se", At: firstSeen, Source: "historical_registration"})
		if imported.ID != machine.ID {
			t.Fatal("historical session must join the existing alias, not create another machine")
		}
		f.consent(t, "historical", "owner", false, firstSeen)
		f.consent(t, "current", "owner", false, f.start)
		f.earning(t, "historical", "owner", 70, f.optIn.Add(-48*time.Hour))
		first := f.consent(t, "current", "owner", true, f.optIn)
		for _, got := range []earningsfloor.Enrollment{first, readAutopilotRewardEnrollment(t, f, machine.ID)} {
			if got.MachineID != machine.ID || got.BaselineKnown || got.FirstOptInAt != nil || got.SevenDayEarningsMicroUSD != 0 || got.DailyFloorMicroUSD != 0 || got.BaselineEvidence != "" || !got.FirstObservedAt.Equal(f.optIn) || !got.NextDay.Equal(f.optIn.Truncate(24*time.Hour)) {
				t.Fatalf("canonical creation time hid the imported pre-tracking session: %+v", got)
			}
		}
	})
}

func TestAutopilotRewardsEarlierUnresolvedOptInBlocksAutoBaseline(t *testing.T) {
	for _, earlierAccount := range []string{"owner", "unrelated-owner"} {
		t.Run(earlierAccount, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				earlier := f.optIn.Add(-24 * time.Hour)
				if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "unresolved", AccountID: earlierAccount, Supported: true, OptedIn: true, At: earlier}); !errors.Is(err, earningsfloor.ErrIdentity) {
					t.Fatalf("unbound original declaration = %v", err)
				}
				machine := f.observe(t, store.MachineObservation{SessionID: "current", AccountID: "owner", SEKey: "current-se", At: f.start})
				f.consent(t, "current", "owner", false, f.start)
				f.earning(t, "current", "owner", 70, f.optIn.Add(-time.Hour))
				got := f.consent(t, "current", "owner", true, f.optIn)
				wantKnown := earlierAccount != "owner"
				if got.BaselineKnown != wantKnown || !got.FirstObservedAt.Equal(f.optIn) || (!wantKnown && got.FirstOptInAt != nil) || (wantKnown && (got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) || got.SevenDayEarningsMicroUSD != 70)) {
					t.Fatalf("unresolved account history was ignored or falsely associated: %+v", got)
				}
				other := f.observe(t, store.MachineObservation{SessionID: "unresolved", AccountID: earlierAccount, SEKey: "other-se", At: f.optIn.Add(time.Hour)})
				if other.ID == machine.ID {
					t.Fatal("unrelated sessions were associated without evidence")
				}
				if after := readAutopilotRewardEnrollment(t, f, machine.ID); after.BaselineKnown != wantKnown || !after.FirstObservedAt.Equal(f.optIn) || (!wantKnown && after.FirstOptInAt != nil) {
					t.Fatalf("later binding auto-repaired an unknown frozen history: %+v", after)
				}
			})
		})
	}
}

func TestAutopilotRewardsMergePreservesBaselineAndReceipts(t *testing.T) {
	t.Run("ancestor_receipts_and_cursor", func(t *testing.T) {
		autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
			var enrollments []earningsfloor.Enrollment
			var receipts []earningsfloor.Settlement
			f.fund(t, 1000)
			for i, session := range []string{"earliest", "middle", "canonical"} {
				f.observe(t, store.MachineObservation{SessionID: session, AccountID: "owner", SEKey: session + "-se", At: f.start})
				f.consent(t, session, "owner", false, f.start)
				at := f.optIn.AddDate(0, 0, i)
				f.earning(t, session, "owner", int64(70*(i+1)), at.Add(-48*time.Hour))
				enrollment := f.consent(t, session, "owner", true, at)
				enrollments = append(enrollments, enrollment)
				receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay)
				if receipt.Status != earningsfloor.Paid || receipt.AmountMicroUSD != int64(11*(i+1)) {
					t.Fatalf("independent pre-merge settlement %d: %+v", i, receipt)
				}
				receipts = append(receipts, receipt)
			}
			for i, link := range []struct{ winner, loser string }{{"middle", "earliest"}, {"canonical", "middle"}} {
				at := f.optIn.Add(time.Duration(72+i*2) * time.Hour)
				winner := f.observe(t, store.MachineObservation{SessionID: link.winner, AccountID: "owner", SEKey: link.winner + "-se", VerifiedSerial: link.winner + "-serial", At: at})
				merged := f.observe(t, store.MachineObservation{SessionID: link.loser, AccountID: "owner", SEKey: link.loser + "-se", VerifiedSerial: link.winner + "-serial", At: at.Add(time.Hour)})
				if merged.ID != winner.ID {
					t.Fatal("fixture did not create the canonical merge chain")
				}
			}
			canonical := enrollments[2].MachineID
			rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100)
			if err != nil || len(rows) != 1 {
				t.Fatalf("merged enrollment projection = %+v, %v", rows, err)
			}
			selected := rows[0]
			if selected.MachineID != canonical || selected.FirstOptInAt == nil || !selected.FirstOptInAt.Equal(f.optIn) || selected.SevenDayEarningsMicroUSD != 70 || selected.DailyFloorMicroUSD != 11 || !selected.NextDay.Equal(enrollments[1].NextDay) {
				t.Fatalf("merge replaced or summed the earliest frozen baseline: %+v", selected)
			}
			// A later ancestor receipt is replayable but cannot skip the selected
			// enrollment's outstanding day. Older replays cannot rewind it either.
			for _, i := range []int{2, 0} {
				if got := f.settle(t, canonical, receipts[i].Day); got != receipts[i] {
					t.Fatalf("merge rewrote original receipt %d: %+v, want %+v", i, got, receipts[i])
				}
				if got := readAutopilotRewardEnrollment(t, f, canonical); !got.NextDay.Equal(selected.NextDay) {
					t.Fatalf("non-current replay moved selected cursor: %+v", got)
				}
			}
			for _, i := range []int{1, 2} {
				if got := f.settle(t, enrollments[0].MachineID, receipts[i].Day); got != receipts[i] {
					t.Fatalf("ancestor %d paid twice or lost receipt provenance: %+v", i, got)
				}
				if got := readAutopilotRewardEnrollment(t, f, canonical); !got.NextDay.Equal(receipts[i].Day.AddDate(0, 0, 1)) {
					t.Fatalf("current ancestor replay did not advance selected cursor: %+v", got)
				}
			}
			newDay := receipts[2].Day.AddDate(0, 0, 1)
			paid := f.settle(t, canonical, newDay)
			if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 || paid.MachineID != enrollments[0].MachineID {
				t.Fatalf("post-merge payment lost the original enrollment: %+v", paid)
			}
			for _, enrollment := range enrollments {
				if got := f.settle(t, enrollment.MachineID, newDay); got != paid {
					t.Fatalf("alias replay changed receipt: %+v, want %+v", got, paid)
				}
			}
			pool, err := f.rewards.AutopilotRewardPool(t.Context())
			if err != nil || pool.SpentMicroUSD != 77 || f.backend.GetBalance("owner") != 77 {
				t.Fatalf("merge/replay changed total credits: pool=%+v, %v, balance=%d", pool, err, f.backend.GetBalance("owner"))
			}
		})
	})
	t.Run("conflicting_final_receipts", func(t *testing.T) {
		autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
			first, second := f.enroll(t, "first", "owner", 70), f.enroll(t, "second", "owner", 140)
			f.fund(t, 1000)
			f.settle(t, first.MachineID, first.NextDay)
			f.settle(t, second.MachineID, second.NextDay)
			f.observe(t, store.MachineObservation{SessionID: "first", AccountID: "owner", SEKey: "first-se", VerifiedSerial: "same", At: f.optIn.Add(time.Hour)})
			merged := f.observe(t, store.MachineObservation{SessionID: "second", AccountID: "owner", SEKey: "second-se", VerifiedSerial: "same", At: f.optIn.Add(2 * time.Hour)})
			for _, id := range []string{merged.ID, second.MachineID} {
				if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), id, first.NextDay); !errors.Is(err, earningsfloor.ErrIdentity) {
					t.Fatalf("ambiguous ancestral receipts were silently selected: %v", err)
				}
			}
			if got := f.backend.GetBalance("owner"); got != 33 {
				t.Fatalf("conflicting receipts produced another credit: %d", got)
			}
		})
	})
}

func TestAutopilotRewardsEarlierUnknownAliasFlagsFrozenHistory(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		legacySeen := f.start.Add(-48 * time.Hour)
		legacy := f.observe(t, store.MachineObservation{SessionID: "legacy", AccountID: "owner", SEKey: "legacy-se", At: legacySeen})
		f.consent(t, "legacy", "owner", false, legacySeen)
		f.earning(t, "legacy", "owner", 70, f.optIn.Add(-48*time.Hour))
		unknown := f.consent(t, "legacy", "owner", true, f.optIn)
		if unknown.BaselineKnown || unknown.FirstOptInAt != nil || !unknown.FirstObservedAt.Equal(f.optIn) {
			t.Fatalf("legacy fixture did not retain unknown first-ever history: %+v", unknown)
		}
		canonical := f.observe(t, store.MachineObservation{SessionID: "known", AccountID: "owner", SEKey: "known-se", VerifiedSerial: "canonical-serial", At: f.start})
		f.consent(t, "known", "owner", false, f.start)
		f.earning(t, "known", "owner", 140, f.optIn.Add(-48*time.Hour))
		anchor := f.optIn.Add(time.Hour)
		frozen := f.consent(t, "known", "owner", true, anchor)
		if !frozen.BaselineKnown || frozen.HistoryConflict || frozen.FirstOptInAt == nil || !frozen.FirstOptInAt.Equal(anchor) || frozen.SevenDayEarningsMicroUSD != 140 {
			t.Fatalf("independent known baseline = %+v", frozen)
		}
		merged := f.observe(t, store.MachineObservation{SessionID: "legacy", AccountID: "owner", SEKey: "legacy-se", VerifiedSerial: "canonical-serial", At: f.optIn.Add(2 * time.Hour)})
		if merged.ID != canonical.ID || merged.ID == legacy.ID {
			t.Fatal("unknown alias did not merge into the known canonical identity")
		}
		rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100)
		if err != nil || len(rows) != 1 {
			t.Fatalf("conflicted canonical enrollment was skipped or rejected: %+v, %v", rows, err)
		}
		got := rows[0]
		if got.MachineID != canonical.ID || !got.HistoryConflict || !got.BaselineKnown || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(anchor) || !got.FirstObservedAt.Equal(anchor) || got.SevenDayEarningsMicroUSD != 140 || got.DailyFloorMicroUSD != 22 || got.BaselineEvidence != frozen.BaselineEvidence || !got.OptedIn || !got.ObservedAt.Equal(anchor) || !got.NextDay.Equal(frozen.NextDay) {
			t.Fatalf("earlier unknown enrollment was ignored or re-anchored the snapshot: %+v", got)
		}
		if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: legacy.ID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "legacy-history-audit"}); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
			t.Fatalf("merged conflicted baseline accepted ordinary restore: %v", err)
		}
		f.fund(t, 1000)
		if pending := f.settle(t, canonical.ID, frozen.NextDay); pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
			t.Fatalf("merged conflict did not withhold new payment: %+v", pending)
		}
		if got := readAutopilotRewardEnrollment(t, f, canonical.ID); !got.HistoryConflict || !got.NextDay.Equal(frozen.NextDay) {
			t.Fatalf("merged conflict advanced or disappeared: %+v", got)
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 0 || f.backend.GetBalance("owner") != 0 {
			t.Fatalf("merged unknown history moved money: %+v, %v", pool, err)
		}
	})
}

func TestAutopilotRewardsRejectsConflictingOwners(t *testing.T) {
	for _, source := range []string{"inventory", "provider_session"} {
		t.Run(source, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				observation := store.MachineObservation{SessionID: "session", AccountID: "owner", SEKey: "se", At: f.start}
				if source == "inventory" {
					f.observe(t, observation)
				} else if err := f.backend.OpenProviderSession(t.Context(), "session", "", "owner"); err != nil {
					t.Fatal(err)
				}
				if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "session", AccountID: "intruder", Supported: true, OptedIn: true, At: f.optIn}); !errors.Is(err, earningsfloor.ErrIdentity) {
					t.Fatalf("accepted known wrong session owner: %v", err)
				}
				f.observe(t, observation)
				f.consent(t, "session", "owner", false, f.start)
				f.earning(t, "session", "owner", 70, f.optIn.Add(-time.Hour))
				got := f.consent(t, "session", "owner", true, f.optIn)
				if got.AccountID != "owner" || !got.BaselineKnown || got.SevenDayEarningsMicroUSD != 70 {
					t.Fatalf("rejected wrong owner poisoned the consent journal: %+v", got)
				}
			})
		})
	}
	t.Run("canonical_multi_owner", func(t *testing.T) {
		autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
			first := f.enroll(t, "first", "owner", 70)
			f.enroll(t, "second", "other-owner", 140)
			f.fund(t, 1000)
			f.observe(t, store.MachineObservation{SessionID: "first", AccountID: "owner", SEKey: "first-se", VerifiedSerial: "same-hardware", At: f.optIn.Add(time.Hour)})
			merged := f.observe(t, store.MachineObservation{SessionID: "second", AccountID: "other-owner", SEKey: "second-se", VerifiedSerial: "same-hardware", At: f.optIn.Add(2 * time.Hour)})
			if merged.ID != first.MachineID {
				t.Fatal("fixture did not produce a multi-owner canonical identity")
			}
			if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "first", AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn.Add(3 * time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
				t.Fatalf("multi-owner consent = %v", err)
			}
			if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: merged.ID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "audit"}); !errors.Is(err, earningsfloor.ErrIdentity) {
				t.Fatalf("multi-owner baseline mutation = %v", err)
			}
			if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), merged.ID, first.NextDay); !errors.Is(err, earningsfloor.ErrIdentity) {
				t.Fatalf("multi-owner financial settlement = %v", err)
			}
			pool, err := f.rewards.AutopilotRewardPool(t.Context())
			if err != nil || pool.SpentMicroUSD != 0 || f.backend.GetBalance("owner") != 0 || f.backend.GetBalance("other-owner") != 0 {
				t.Fatalf("ambiguous ownership moved money: %+v, %v", pool, err)
			}
		})
	})
}

func TestAutopilotRewardsEarningAttribution(t *testing.T) {
	t.Run("authoritative_session_and_owned_fallback", func(t *testing.T) {
		autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
			for _, session := range []struct{ id, account, key string }{{"first", "owner", "first-key"}, {"second", "owner", "second-key"}, {"foreign", "other-owner", "first-key"}} {
				f.observe(t, store.MachineObservation{SessionID: session.id, AccountID: session.account, SEKey: session.id + "-se", At: f.start})
				f.consent(t, session.id, session.account, false, f.start)
				if err := f.backend.OpenProviderSession(t.Context(), session.id, "", session.account); err != nil {
					t.Fatal(err)
				}
				if err := f.backend.TouchProviderSession(t.Context(), session.id, "", session.account, session.key, f.start); err != nil {
					t.Fatal(err)
				}
			}
			for _, row := range []struct {
				provider, account, key string
				amount                 int64
			}{
				{"first", "owner", "second-key", 21},
				{"legacy-first", "owner", "first-key", 49},
				{"second", "owner", "first-key", 42},
				{"", "owner", "second-key", 98},
				{"foreign", "owner", "first-key", 10000},
				{"first", "other-owner", "first-key", 20000},
			} {
				if err := f.backend.RecordProviderEarning(&store.ProviderEarning{AccountID: row.account, ProviderID: row.provider, ProviderKey: row.key, JobID: uniqueID("attribution"), Model: "model", AmountMicroUSD: row.amount, CreatedAt: f.optIn.Add(-48 * time.Hour)}); err != nil {
					t.Fatal(err)
				}
			}
			first := f.consent(t, "first", "owner", true, f.optIn)
			second := f.consent(t, "second", "owner", true, f.optIn)
			if first.MachineID == second.MachineID || !first.BaselineKnown || !second.BaselineKnown || first.SevenDayEarningsMicroUSD != 70 || second.SevenDayEarningsMicroUSD != 140 {
				t.Fatalf("session/key attribution crossed machines or owners: first=%+v, second=%+v", first, second)
			}
			f.fund(t, 1000)
			for i, enrollment := range []earningsfloor.Enrollment{first, second} {
				if got := f.settle(t, enrollment.MachineID, enrollment.NextDay); got.Status != earningsfloor.Paid || got.AmountMicroUSD != int64(11*(i+1)) {
					t.Fatalf("same-account machines did not settle independently: %+v", got)
				}
			}
		})
	})
	for _, phase := range []string{"baseline", "settlement"} {
		t.Run("ambiguous_key_"+phase, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				var machines []string
				for _, session := range []string{"first", "second"} {
					if phase == "settlement" {
						machines = append(machines, f.enroll(t, session, "owner", 70).MachineID)
					} else {
						machines = append(machines, f.observe(t, store.MachineObservation{SessionID: session, AccountID: "owner", SEKey: session + "-se", At: f.start}).ID)
						f.consent(t, session, "owner", false, f.start)
					}
					if err := f.backend.OpenProviderSession(t.Context(), session, "", "owner"); err != nil {
						t.Fatal(err)
					}
					if err := f.backend.TouchProviderSession(t.Context(), session, "", "owner", "ambiguous-key", f.start); err != nil {
						t.Fatal(err)
					}
				}
				at := f.optIn.Add(-time.Hour)
				if phase == "settlement" {
					at = f.optIn.Add(time.Hour)
				}
				if err := f.backend.RecordProviderEarning(&store.ProviderEarning{AccountID: "owner", ProviderKey: "ambiguous-key", JobID: uniqueID("ambiguous-earning"), Model: "model", AmountMicroUSD: 7, CreatedAt: at}); err != nil {
					t.Fatal(err)
				}
				f.fund(t, 1000)
				for i, session := range []string{"first", "second"} {
					var err error
					if phase == "baseline" {
						_, err = f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: session, AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn})
					} else {
						_, err = f.rewards.SettleAutopilotRewardDay(t.Context(), machines[i], f.optIn.Truncate(24*time.Hour))
					}
					if !errors.Is(err, earningsfloor.ErrIdentity) {
						t.Fatalf("ambiguous legacy key silently attributed during %s: %v", phase, err)
					}
				}
				pool, err := f.rewards.AutopilotRewardPool(t.Context())
				if err != nil || pool.SpentMicroUSD != 0 || f.backend.GetBalance("owner") != 0 {
					t.Fatalf("ambiguous earning moved money: %+v, %v", pool, err)
				}
			})
		})
	}
}
