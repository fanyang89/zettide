cmake_minimum_required(VERSION 3.20)
project(grpc_lite_cmake_c_consumer LANGUAGES C)

if(NOT GRPC_LITE_SOURCE_DIR)
  message(FATAL_ERROR "GRPC_LITE_SOURCE_DIR is required")
endif()

include(FetchContent)
FetchContent_Declare(grpc_lite SOURCE_DIR "${GRPC_LITE_SOURCE_DIR}")
FetchContent_MakeAvailable(grpc_lite)

add_executable(c_consumer_shared main.c)
target_compile_features(c_consumer_shared PRIVATE c_std_11)
target_link_libraries(c_consumer_shared PRIVATE grpc_lite::c)

add_executable(c_consumer_static main.c)
target_compile_features(c_consumer_static PRIVATE c_std_11)
target_link_libraries(c_consumer_static PRIVATE grpc_lite::c_static)

enable_testing()
add_test(NAME grpc_lite_c_shared COMMAND c_consumer_shared)
add_test(NAME grpc_lite_c_static COMMAND c_consumer_static)
