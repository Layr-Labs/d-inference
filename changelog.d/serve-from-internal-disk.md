### The provider reports whether it runs from the Mac's internal disk

- The registration now reports where the provider's executable runs from: the Mac's internal disk, a network volume, removable media, an external disk or a mounted disk image. A release build can also refuse to serve the network from anywhere but the internal disk; that is off by default and `DARKBLOOM_SERVING_VOLUME_CHECK=refuse` turns it on.
