### The provider needs authenticated root enabled to serve

- Darkbloom serving now also stays off when authenticated root (the signed system volume check) is explicitly disabled. On a Mac that serves Darkbloom, `darkbloom doctor` shows `authenticated root` failing, a `darkbloom start` that would install the Darkbloom service stops and names the fix (`csrutil authenticated-root enable` in recoveryOS), and a running service holds without connecting. When the setting can't be read, `darkbloom doctor` and `darkbloom status` only warn. Only me (`darkbloom start --local`) still serves your own requests.
- The provider reports the setting when it registers (`authenticated_root`), only when it could read it.
- The boot settings reading gives each of its commands a time limit, so a command that doesn't answer can't hold up a start.
