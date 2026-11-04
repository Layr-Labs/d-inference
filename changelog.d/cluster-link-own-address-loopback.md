### A paired Mac's cable port is no longer reported as not isolated

- `darkbloom cluster link` and `darkbloom cluster doctor` no longer report a paired Mac's cable port as not isolated ("the cluster subnet 10.219/16 is already used on this Mac") because macOS routes the port's own address through the loopback.
