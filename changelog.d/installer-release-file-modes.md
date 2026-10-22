### Installer release file modes

- Extract the release bundle under umask 022 with `/usr/bin/tar`, so a restrictive caller umask no longer leaves installed app files owner-only. Private state created elsewhere by the installer is unchanged.
