### The provider needs authenticated root enabled to serve

- Darkbloom serving now also stays off while authenticated root (the signed system volume check) is turned off; `darkbloom doctor` shows `authenticated root` failing, and `darkbloom start` names the fix (`csrutil authenticated-root enable` in recoveryOS). When the setting can't be read it only warns. Only me (`darkbloom start --local`) still serves your own requests.
- The provider reports the setting when it registers (`authenticated_root`), when it can read it.
