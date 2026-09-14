#include "SandboxHostContextSupport.h"
#include <bsm/audit.h>
#include <errno.h>

int darkbloom_current_audit_user(uint32_t *output) {
    if (output == 0) {
        errno = EINVAL;
        return -1;
    }
    au_id_t value = 0;
    int result = getauid(&value);
    if (result == 0) {
        *output = value;
    }
    return result;
}
