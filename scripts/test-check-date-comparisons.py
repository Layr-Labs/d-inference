#!/usr/bin/env python3
"""The source check finds Date `>=` and `<=`, and leaves other comparisons alone."""
import importlib.util
import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("date_comparisons", ROOT / "scripts/check-date-comparisons.py")
date_comparisons = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(date_comparisons)

# The forms that DevNet build 0.10.6-dev.branch.87 compiled into weak imports.
# `day >= since` is the one that the first version of the check missed: `day`
# is bound from date(from:) in a scope that shadows a String `day`, and
# `since` from a ternary. Also an initializer with nested parentheses against
# another type's member that returns a Date, and an operator passed as a function.
REFUSED = """\
import Foundation
struct Row { let at: Date }
struct Policy {
    var nextSync = Date()
    func due() -> Bool { Date() >= nextSync }
    func mayGenerateKey(at now: Date, allowed: Date) -> Bool { now >= allowed }
    func restarted(lastVerifiedAt: Date, lastRestartAt: Date) -> Bool { lastVerifiedAt <= lastRestartAt }
    func recent(_ rows: [Row], now: Date) -> [Row] { rows.filter { $0.at >= now.addingTimeInterval(-86400) } }
    func retry(_ at: [String: Date], key: String, now: Date) -> Bool { at[key].map({ now >= $0 }) ?? true }
    func merged(_ a: DateInterval, _ b: DateInterval) -> Bool { a.start <= b.end }
    func covered(day: Date, since: Date, calendar: Calendar) -> Bool { day >= calendar.startOfDay(for: since) }
    func latest(_ dates: [Date]) -> [Date] { dates.sorted(by: >=) }
    func today(_ seconds: Int64) -> Bool { Date(timeIntervalSince1970: TimeInterval(seconds)) >= Calendar.current.startOfDay(for: Date()) }
    func complete(_ rows: [Row], start: Date, iso: ISO8601DateFormatter) -> [Bool] {
        for row in rows { let day = String(iso.string(from: row.at).prefix(10)); print(day) }
        let since = rows.isEmpty ? start : max(start, rows[0].at)
        return rows.map { _ in
            let day = iso.date(from: "2026-11-04T00:00:00Z")!
            return day >= since
        }
    }
}
"""
ALLOWED = """\
import Foundation
struct Clock {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var count: Int
    func due() -> Bool { ContinuousClock.now >= deadline }
    func full() -> Bool { count >= 10 }
    func due(at now: Date, next: Date) -> Bool { now.timeIntervalSince(next) >= 0 && now < next.addingTimeInterval(9) }
    func notes() -> String { "Date() >= deadline" } // Date() <= now
    /* a block comment: Date() >= deadline */
    func seconds(now: Double, writtenAt: Double) -> Bool { now - writtenAt <= 2 }
    func waited(started: Date, bound: Double) -> Bool { let waited = Date().timeIntervalSince(started); return waited >= bound }
    func age(bound: Double) -> Bool { let age = Date.now.timeIntervalSince1970; return age <= bound }
}
"""


class DateComparisonTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="date comparisons ")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, name, text):
        path = self.root / name
        path.write_text(textwrap.dedent(text))
        return path

    def test_finds_every_back_deployed_form(self):
        path = self.write("Refused.swift", REFUSED)
        found = [text for _, _, text in date_comparisons.findings([path])]
        self.assertEqual(found, [
            "Date() >= nextSync",
            "now >= allowed",
            "lastVerifiedAt <= lastRestartAt",
            "$0.at >= now.addingTimeInterval(-86400)",
            "now >= $0",
            "a.start <= b.end",
            "day >= calendar.startOfDay(for: since)",
            ">= passed as a function",
            "Date(timeIntervalSince1970: TimeInterval(seconds)) >= Calendar.current.startOfDay(for: Date())",
            "day >= since",
        ])

    def test_leaves_clocks_numbers_strings_comments_and_the_replacement_alone(self):
        path = self.write("Allowed.swift", ALLOWED)
        self.assertEqual(date_comparisons.findings([path]), [])

    def test_a_name_declared_as_a_date_in_another_file_counts(self):
        self.write("Types.swift", "struct Lease { let expiresAt: Date }\n")
        uses = self.write("Uses.swift", "func live(_ lease: Lease, now: Date) -> Bool { lease.expiresAt >= now }\n")
        found = date_comparisons.findings(sorted(self.root.glob("*.swift")))
        self.assertEqual([(path, line) for path, line, _ in found], [(uses, 1)])

    def test_a_name_with_two_types_counts_only_where_it_is_a_date(self):
        self.write("Seconds.swift", "func old(now: Double, at: Double) -> Bool { now >= at }\n")
        dates = self.write("Dates.swift", "func due(now: Date, at: Date) -> Bool { now >= at }\n")
        found = date_comparisons.findings(sorted(self.root.glob("*.swift")))
        self.assertEqual([path for path, _, _ in found], [dates])

    def test_a_parameter_settles_its_name_only_in_its_function(self):
        path = self.write("Lease.swift", """\
            import Foundation
            struct Lease {
                let renewedAt: Date
                let expiresAt: Date
                func old(renewedAt: Double, expiresAt: Double) -> Bool { expiresAt >= renewedAt }
                func live() -> Bool { expiresAt >= renewedAt }
            }
            """)
        self.assertEqual([line for _, line, _ in date_comparisons.findings([path])], [6])

    def test_main_reports_each_finding_and_fails(self):
        self.write("Refused.swift", "func due(next: Date) -> Bool { Date() >= next }\n")
        stderr = io.StringIO()
        with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
            code = date_comparisons.main(["--root", str(self.root), str(self.root / "Refused.swift")])
        self.assertEqual(code, 1)
        self.assertIn("Refused.swift:1: Date comparison `Date() >= next`", stderr.getvalue())

    def test_shipped_provider_source_has_no_back_deployed_comparison(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(io.StringIO()) as stderr:
            code = date_comparisons.main([])
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertIn("No back-deployed Date comparisons", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
