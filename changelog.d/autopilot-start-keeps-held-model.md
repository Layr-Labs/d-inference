### `darkbloom start` with Autopilot no longer fails on a model an Autopilot download holds

An ordinary start with Autopilot enrolled verifies every enrolled model on disk.
When one of them couldn't be verified at that moment, for example because an
Autopilot download in progress held it, the whole start failed with "Could not
validate every enrolled model". Now the start names that model, keeps it in the
recorded Autopilot inventory unchanged, and serves as usual while at least one
other enrolled model verified; the running provider checks the held model again.
A model missing from disk or the catalog, or no longer eligible, and a start
where no enrolled model verifies, still fail as before.
