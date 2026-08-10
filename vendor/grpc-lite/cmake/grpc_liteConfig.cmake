get_filename_component(_grpc_lite_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
get_filename_component(_grpc_lite_libdir "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

include(CMakeFindDependencyMacro)
find_dependency(Threads)

if(NOT TARGET grpc_lite::c)
  add_library(grpc_lite::c SHARED IMPORTED)
  set_target_properties(grpc_lite::c PROPERTIES
    IMPORTED_LOCATION "${_grpc_lite_libdir}/libgrpc_lite.so"
    INTERFACE_INCLUDE_DIRECTORIES "${_grpc_lite_prefix}/include")
endif()

if(NOT TARGET grpc_lite::c_static)
  add_library(grpc_lite::c_static STATIC IMPORTED)
  set_target_properties(grpc_lite::c_static PROPERTIES
    IMPORTED_LOCATION "${_grpc_lite_libdir}/libgrpc_lite.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_grpc_lite_prefix}/include"
    INTERFACE_LINK_LIBRARIES "Threads::Threads;${CMAKE_DL_LIBS};m;rt")
endif()

if(NOT TARGET grpc_lite::grpcpp)
  add_library(grpc_lite::grpcpp INTERFACE IMPORTED)
  set_target_properties(grpc_lite::grpcpp PROPERTIES
    INTERFACE_COMPILE_FEATURES cxx_std_17
    INTERFACE_INCLUDE_DIRECTORIES "${_grpc_lite_prefix}/include"
    INTERFACE_LINK_LIBRARIES grpc_lite::c)
endif()

if(NOT TARGET grpc_lite::protoc-gen-grpc_lite_cpp)
  add_executable(grpc_lite::protoc-gen-grpc_lite_cpp IMPORTED)
  set_target_properties(grpc_lite::protoc-gen-grpc_lite_cpp PROPERTIES
    IMPORTED_LOCATION "${_grpc_lite_prefix}/bin/protoc-gen-grpc_lite_cpp")
endif()

unset(_grpc_lite_prefix)
unset(_grpc_lite_libdir)
