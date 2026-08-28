#include "ProviderMetallibControl.h"

#include <string>

namespace mlx::core::metal {
void set_metallib_path(const std::string& path);
}

void darkbloom_mlx_set_metallib_path(const char *path) {
  mlx::core::metal::set_metallib_path(path == nullptr ? std::string() : std::string(path));
}
