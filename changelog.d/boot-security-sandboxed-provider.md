### The provider doesn't serve from inside a sandbox it didn't set up

- Darkbloom serving now stays off when the provider runs inside a macOS sandbox that something else set up, because Darkbloom can't verify the Mac's boot settings from there. `darkbloom start` stops before its setup and says to start Darkbloom from a standard installation; a running service holds without connecting, and `darkbloom status` and `darkbloom doctor` say why. `doctor` also checks its own process (`process sandbox`). Only me (`darkbloom start --local`) still serves your own requests.
- When the Secure Boot setting can't be read, the provider now reports it as `unknown` when it registers, instead of leaving it out. On the Mac this still only warns.
