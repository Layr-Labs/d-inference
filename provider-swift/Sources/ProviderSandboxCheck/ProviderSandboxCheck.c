#include "ProviderSandboxCheck.h"

#include <dlfcn.h>
#include <stddef.h>
#include <unistd.h>

// `sandbox_check` (libsystem_sandbox) is not in the public SDK headers. Its
// filter type is an enum whose SANDBOX_FILTER_NONE is 0; filter arguments,
// when a filter is given, follow as variadic arguments.
typedef int (*sandbox_check_fn)(pid_t pid, const char *operation, int type, ...);

int provider_sandbox_check_self(void) {
    sandbox_check_fn check = (sandbox_check_fn)dlsym(RTLD_DEFAULT, "sandbox_check");
    if (check == NULL) {
        return -2;
    }
    return check(getpid(), NULL, 0);
}
