#ifndef DARKBLOOM_SANDBOX_HOST_CONTEXT_SUPPORT_H
#define DARKBLOOM_SANDBOX_HOST_CONTEXT_SUPPORT_H

#include <stdint.h>

// Public libbsm query for the current process only. No session is changed.
int darkbloom_current_audit_user(uint32_t *output);

#endif
