### Provider status App Attest lease

- Keep `darkbloom status` and `darkbloom doctor` reporting App Attest authorization until the coordinator lease expires. They required a renewal within the last 10 seconds, so one delayed renewal showed `Trust: self_signed / online` although serving continued. `darkbloom unenroll` still requires a renewal within 10 seconds before offering MDM removal.
