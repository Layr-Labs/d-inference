### Both Macs say when single-Mac serving blocks the pair

- The Mac that joined now shows the same ✗ as the leading Mac when single-Mac serving blocks the pair. The ✗ names its own single-Mac provider and process, and gives `darkbloom stop --solo`. It also says that the leading Mac's screen offers to stop it and start the pair. Before, that window said "registering with the coordinator" for minutes. Once single-Mac serving stops, it follows the start by itself.
- Each Mac reports single-Mac serving as soon as it runs, not only once the pair wants to start. So the leading Mac sees it before anything starts.
- The leading Mac's part no longer starts and ends every 38 seconds while the other Mac reports single-Mac serving. It waits until that changes. The same rule covers any reason the other Mac reports that its part can't start.
- In `darkbloom cluster status`, `Next:` now says what to run on both Macs instead of "Both Macs keep trying by themselves". A `darkbloom start` run from a script ends its wait at once for this reason.
