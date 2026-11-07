### Local-first settings in provider.toml

- `provider.toml` takes a new `[local]` section for using your Mac yourself, beside or instead of Darkbloom: `mode`,
  `me_first`, `me_first_idle_minutes` (default 2, from 1 to 120), `route`, `port` and `bind`. The provider reads and
  checks it. Serving uses `mode`, `me_first` and `me_first_idle_minutes` for the local API beside Darkbloom; it does
  not use `route`, `port` or `bind` yet.
- Without `[local]`, nothing changes. A value the section can't take stops the provider at startup with one plain line
  that names the key, for example `[local] me_first_idle_minutes must be a whole number of minutes from 1 to 120, not 0.`
