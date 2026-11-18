### Release builds ignore developer-only cluster switches

- Release builds ignore developer-only cluster switches. A setup that reaches the other Mac over SSH is a developer harness only: a release build refuses it and serves a pair only over the link (pair the Macs with `darkbloom cluster`).
