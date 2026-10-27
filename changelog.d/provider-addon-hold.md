### Reversible add-on hold

- A signed local add-on, such as the Darkbloom Sandbox, can hold the provider
  through the owner-only socket `~/.darkbloom/runtime/addon.sock` while its VMs
  run. The provider stays connected, reports `status: draining` with
  `busy_reason`, `busy_since_ms` and `busy_addon`, lets accepted work finish
  (up to 120 seconds), then unloads every model. Release returns it to routing
  on the same connection.
- Holds have 30–600 second leases. An expired lease ends the hold only when the
  add-on no longer holds `ownership.lock`, and a restarted or updated provider
  comes back held without loading models.
- Updates and Autopilot operations wait for the hold, and reconnects keep it;
  Autopilot reports `addon_hold`. `darkbloom addon status|hold|release`
  inspects or overrides holds for debugging, and `darkbloom status` shows an
  active hold.
- Coordinator handling of the busy fields ships separately; older coordinators
  still stop routing on the draining status.
