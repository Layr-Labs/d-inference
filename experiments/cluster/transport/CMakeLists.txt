cmake_minimum_required(VERSION 3.24)

# This probe must compile the real RDMA backend, never the older-OS stub.
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.2" CACHE STRING "Minimum macOS version")
project(darkbloom_cluster_transport LANGUAGES CXX OBJCXX)
if(NOT APPLE OR CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "26.2")
  message(FATAL_ERROR "The transport probe requires macOS and deployment target >= 26.2")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

get_filename_component(REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
add_subdirectory("${REPOSITORY_ROOT}/libs/mlx/mlx/distributed/jaccl/lib" jaccl EXCLUDE_FROM_ALL)
if(NOT TARGET jaccl)
  message(FATAL_ERROR "JACCL did not build; select a macOS SDK >= 26.2")
endif()

add_executable(cluster-transport-probe main.cpp benchmark.cpp metal_buffers.mm)
target_link_libraries(cluster-transport-probe PRIVATE jaccl nlohmann_json::nlohmann_json
  "-framework Foundation" "-framework Metal")
target_compile_options(cluster-transport-probe PRIVATE -Wall -Wextra -Wpedantic
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
