# SPDX-License-Identifier: LGPL-3.0-or-later
if(NOT ZETTIDE_SOURCE_DIR)
  get_filename_component(ZETTIDE_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
endif()

set(ZETTIDE_BACKEND_LIBRARY
    "${ZETTIDE_SOURCE_DIR}/zig-out/lib/libzettide-nfs-backend.a"
    CACHE FILEPATH "Path to libzettide-nfs-backend.a")
if(NOT EXISTS "${ZETTIDE_BACKEND_LIBRARY}")
  message(FATAL_ERROR
          "Build the Zettide backend first: zig build -Doptimize=ReleaseSafe")
endif()

add_library(fsalzettide MODULE
  export.c
  handle.c
  main.c
)

target_include_directories(fsalzettide PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}"
  "${ZETTIDE_SOURCE_DIR}/src"
)
target_compile_definitions(fsalzettide PRIVATE _GNU_SOURCE)
target_link_libraries(fsalzettide PRIVATE
  ganesha_nfsd
  "${ZETTIDE_BACKEND_LIBRARY}"
  stdc++
  ${SYSTEM_LIBRARIES}
  ${LDFLAG_DISALLOW_UNDEF}
)
set_target_properties(fsalzettide PROPERTIES VERSION 4.2.0 SOVERSION 4)
install(TARGETS fsalzettide COMPONENT fsal DESTINATION ${FSAL_DESTINATION})
