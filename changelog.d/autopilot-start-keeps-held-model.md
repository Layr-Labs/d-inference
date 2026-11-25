### `darkbloom start` with Autopilot no longer fails on a model an Autopilot download holds

An ordinary start with Autopilot enrolled verifies every enrolled model on disk.
When another process held one of them at that moment, for example an Autopilot
download in progress, the whole start failed with "Could not validate every
enrolled model". Now the start names that model, keeps it in the recorded
Autopilot inventory unchanged, and serves as usual while at least one other
enrolled model verified; the provider hashes the held model again when it
starts. A build that fails its check, a model missing from disk or the catalog,
or no longer eligible, and a start where no enrolled model verifies, still fail
as before.
