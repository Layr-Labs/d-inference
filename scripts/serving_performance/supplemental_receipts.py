"""Summaries for direct integration and real serving-set checks, never promotion."""


def supplemental_summary(report):
    competing = report.get("kind") == "competing_models_supplement"
    trials = report.get("trials", [])
    complete = report.get("complete") is True and bool(trials)
    if competing:
        passed = complete and all(trial.get("passed") is True and trial.get("overlapProven") is True
            and trial.get("retired") is True and trial.get("competitorCancelled") is True for trial in trials)
        return {"qualified": False, "kind": "competing_models_supplement", "passed": passed,
                "trials": len(trials), "proven_overlap_trials": sum(t.get("overlapProven") is True for t in trials),
                "promotion_blockers": ["supplemental serving-set observations do not qualify either model or other_model cells"]}
    rows = [row for trial in trials for row in trial.get("rows", [])]
    require_calibrated = report.get("job", {}).get("requireCalibratedAdmission") is True
    passed = complete and bool(rows) and all(row.get("failure") is None
        and (row.get("deadlineEvidence") or {}).get("deliveredWithinBudget") is True
        and (not require_calibrated or ((row.get("deadlineEvidence") or {}).get("calibratedPathProven") is True
            and (row.get("deadlineEvidence") or {}).get("legacyWouldReject") is True))
        for row in rows)
    return {"qualified": False, "kind": "deadline_integration", "passed": passed, "rows": len(rows),
            "calibrated_rows_proven": sum((r.get("deadlineEvidence") or {}).get("calibratedPathProven") is True for r in rows),
            "legacy_rejection_rows": sum((r.get("deadlineEvidence") or {}).get("legacyWouldReject") is True for r in rows),
            "promotion_blockers": ["deadline integration outcomes are not independent calibration or holdout samples"]}
