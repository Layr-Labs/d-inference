#ifndef PROVIDER_SANDBOX_CHECK_H
#define PROVIDER_SANDBOX_CHECK_H

/// libSystem's `sandbox_check(getpid(), NULL, SANDBOX_FILTER_NONE)` for this
/// process, called through its variadic prototype: 1 when the process runs
/// inside a sandbox, 0 when it doesn't, -1 when the check fails, and -2 when
/// the call is missing.
int provider_sandbox_check_self(void);

#endif
