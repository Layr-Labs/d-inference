### The provider doesn't serve from inside a sandbox it didn't set up

- Darkbloom serving now stays off when the provider runs inside a macOS sandbox that something else set up, because it can't check the Mac's boot security from there. `darkbloom doctor` shows it as `process sandbox` and `darkbloom start` says to start Darkbloom outside that sandbox. Only me (`darkbloom start --local`) still serves your own requests.
- When the Secure Boot setting can't be read, the provider now reports it as `unknown` when it registers, instead of leaving it out.
