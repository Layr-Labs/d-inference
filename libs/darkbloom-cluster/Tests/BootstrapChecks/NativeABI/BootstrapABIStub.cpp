#include "mlx/c/private/mlx.h"
#include "mlx/c/error.h"
extern "C" mlx_distributed_group mlx_distributed_group_new(void) { return {nullptr}; }
extern "C" int mlx_distributed_group_free(mlx_distributed_group group) {
  delete static_cast<mlx::core::distributed::Group*>(group.ctx); return 0;
}
extern "C" void _mlx_error(const char*, int, const char*, ...) { }
extern "C" void bootstrap_test_clear_cache(void) { mlx::core::distributed::cache = {}; }
