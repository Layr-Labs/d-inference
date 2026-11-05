### The single-Mac block shows on both Macs when the pair is stopped

- When you start a stopped pair from the leading Mac and single-Mac serving blocks it, the joining Mac's `darkbloom cluster` screen now shows the same ✗ instead of "Stopped … Close". It names the provider and process, gives `darkbloom stop --solo`, and says that the leading Mac's screen offers to stop it. Both Macs' `darkbloom cluster status` say the block too (`not_serving` with its reason, exit 3) while single-Mac serving runs, instead of `stopped` with no reason.
