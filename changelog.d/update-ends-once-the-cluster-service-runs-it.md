### `darkbloom update` on a pair Mac ends once this Mac runs the new release

- `darkbloom update` on a Mac set up with `darkbloom cluster` could wait its full 10 minutes and end with "Still
  waiting after 600 s", although the Mac had already restarted into the new release: the restarted cluster service
  reports that no update runs, and the command waited to see its own request reach "restarting".
- It now also ends as soon as this Mac's cluster service runs the release it installed, and says so: `This Mac's
  cluster service now runs v<version>; the cluster sets itself up again once both Macs run it.`
