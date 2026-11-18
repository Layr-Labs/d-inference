### The provider needs authenticated root enabled to serve

- Darkbloom serving now also stays off when authenticated root (the signed system volume check) is explicitly disabled. On a Mac that serves Darkbloom, `darkbloom doctor` shows `authenticated root` failing, a `darkbloom start` that installs the Darkbloom service stops and names the fix (`csrutil authenticated-root enable` in recoveryOS), and a running service holds without connecting. When the setting can't be read it only warns. Only me (`darkbloom start --local`) still serves your own requests.
- The provider reports the setting when it registers (`authenticated_root`), only when it could read it.
