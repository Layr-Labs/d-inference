### The provider says why it couldn't read Secure Boot, and reads it again

- When `system_profiler` can't report the Secure Boot setting, the provider reads it again for up to about a minute before it starts serving, and once more before each connection to Darkbloom while it stays unread. One failed read is no longer reported as `unknown`.
- When it stays unread, the registration says why (`secure_boot_read_failure`: `timed_out`, `launch_failed`, `exit_status`, `not_json`, `no_report`, `no_value` or `unrecognized_value`) and after how many reads (`secure_boot_read_attempts`). The provider's log records each failed read with its details, and `darkbloom doctor` and `darkbloom status` name the reason.
- A `Reduced Security` or `Permissive Security` setting found on a later read keeps Darkbloom serving off, like one found on the first read.
