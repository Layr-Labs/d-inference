#ifndef DARKBLOOM_SANDBOX_HOST_CONTEXT_SUPPORT_H
#define DARKBLOOM_SANDBOX_HOST_CONTEXT_SUPPORT_H

#include <stdint.h>

// Public libbsm query for the current process only. No session is changed.
int darkbloom_current_audit_user(uint32_t *output);

// Public membership identity query. Callers must reject synthesized UUIDs.
int darkbloom_user_generated_uuid(uint32_t uid, uint8_t output[16]);

#endif
