### Provider release: every packaged executable keeps mode 0755

- Unsigned staging gives the CLI, the enclave and fan helpers and both cluster helpers mode `0755`, whatever mode the build left. A build under `umask 077` left the CLI, enclave and fan helper `0700`, and the installer and the final release check refuse a fan helper whose mode is not `0755`.
- Unpack refuses an unsigned app in which one of them, or any other Mach-O file in the app, has another mode. The signing job copies the app with `cp -pR`, so its own umask no longer changes the modes, and checks them again before its smoke and signing.
- The executables' bytes, signatures and runtime behavior are unchanged.
