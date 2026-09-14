#include "SandboxHostContextSupport.h"
#include <errno.h>
#include <sys/types.h>
#include <membership.h>
#include <string.h>
#include <uuid/uuid.h>

int darkbloom_user_generated_uuid(uint32_t uid, uint8_t output[16]) {
    if (output == NULL) return EINVAL;
    uuid_t value;
    int status = mbr_uid_to_uuid((uid_t)uid, value);
    if (status == 0) memcpy(output, value, sizeof(value));
    return status;
}
