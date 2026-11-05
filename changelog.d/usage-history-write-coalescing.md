### Coalesced local usage-history writes

The provider no longer rewrites `~/.darkbloom/usage-history.json` after every served request. Completed requests are saved together at most once a minute and on shutdown or update restart, keeping the existing file format, owner-only permissions and atomic replacement. At high request rates this cuts the journal's SSD writes from roughly 1 MB per request (tens of GB per day) to at most about 1.4 GB per day. The desktop app may show the newest requests as pending for up to a minute.
