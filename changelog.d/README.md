# Pending Changelog Entries

Add one unique lowercase kebab-case `.md` file per change; this README is ignored.
Start with `### Concise topic`, a blank line, then prose or bullets.
Nested lists, fenced code and deeper headings are allowed; extra level 1-3
headings, duplicate topics and merge markers are rejected.

Run `python3 scripts/changelog.py check` to validate pending entries.
Run `python3 scripts/changelog.py preview` to print them in filename order.
Release preparation uses `python3 scripts/changelog.py render --version X.Y.Z
--date YYYY-MM-DD [NAME.md ...]` to print a release section for review.
Explicit basenames select a subset; use them for mixed release scopes so later
or unrelated entries remain pending. Dates are explicit, never inferred.
All commands are read-only. Insert reviewed output once into `CHANGELOG.md` and
remove exactly the included fragments in the same release-preparation commit.

See the [contribution guidance](../CONTRIBUTING.md#changelog-entries-with-less-merge-contention).
