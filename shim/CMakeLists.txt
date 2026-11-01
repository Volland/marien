# Marien's extension: the C++ shim and the C runtime bridge compiled against the pinned LadybugDB
# headers, linked with Marien's and LeanElpi's Lean archives and the Lean runtime into ONE shared
# library by the spike's recipe (scripts/link-extension.sh: exports `init` and `name` only;
# Lean, GMP and libuv hidden; libleancpp never linked).
#
#   cmake -S shim -B build/shim [-DLADYBUG_SRC=...] [-DLINK_MODE=strip|nostrip] && cmake --build build/shim
cmake_minimum_required(VERSION 3.20)
project(marien_extension C CXX)

get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
file(READ "${ROOT}/scripts/ladybug-version" LADYBUG_VERSION)
string(STRIP "${LADYBUG_VERSION}" LADYBUG_VERSION)
set(LADYBUG_SRC "${ROOT}/.deps/ladybug" CACHE PATH "LadybugDB source at the pinned tag")
set(LADYBUG_GEN "${LADYBUG_SRC}/build/release" CACHE PATH "Its CMake-configured tree (generated headers)")
set(LINK_MODE strip CACHE STRING "strip (dead-strip unused code) or nostrip")

# The shim is compiled against exactly the LadybugDB release that loads it.
execute_process(COMMAND git -C "${LADYBUG_SRC}" describe --tags --exact-match
  OUTPUT_VARIABLE LADYBUG_TAG OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT LADYBUG_TAG STREQUAL "v${LADYBUG_VERSION}")
  message(FATAL_ERROR "LadybugDB source at ${LADYBUG_SRC} is '${LADYBUG_TAG}', expected v${LADYBUG_VERSION} (scripts/fetch-ladybug.sh)")
endif()
if(NOT EXISTS "${LADYBUG_GEN}/src/include/common/system_config.h")
  message(FATAL_ERROR "${LADYBUG_GEN} is not a configured LadybugDB tree (system_config.h is generated)")
endif()

execute_process(COMMAND lean --print-prefix OUTPUT_VARIABLE LEAN_PREFIX OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND lake env printenv LEAN_PATH WORKING_DIRECTORY "${ROOT}"
  OUTPUT_VARIABLE LEAN_PATH OUTPUT_STRIP_TRAILING_WHITESPACE)
string(REGEX MATCH "[^:]*lean-elpi[^:]*/lib/lean" ELPI_LIB "${LEAN_PATH}")
string(REGEX REPLACE "/lib/lean$" "" ELPI_BUILD "${ELPI_LIB}")
set(MARIEN_A "${ROOT}/.lake/build/lib/libmarien_Marien.a")
set(ELPI_A "${ELPI_BUILD}/lib/liblean_x2delpi_Elpi.a")

add_custom_target(lean_archives
  COMMAND lake build Marien:static Elpi:static
  WORKING_DIRECTORY "${ROOT}"
  BYPRODUCTS "${MARIEN_A}" "${ELPI_A}")

add_library(marien_objs OBJECT lean_bridge.c extension.cpp catalog.cpp scan.cpp structure.cpp)
set_target_properties(marien_objs PROPERTIES
  CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
target_compile_options(marien_objs PRIVATE -O2)
# The version the load-time check compares with; PINNED_VERSION overrides it for the test that a
# mismatched build is refused.
set(PINNED_VERSION "${LADYBUG_VERSION}" CACHE STRING "LadybugDB version the load check expects")
target_compile_definitions(marien_objs PRIVATE NDEBUG MARIEN_LADYBUG_VERSION="${PINNED_VERSION}")
target_include_directories(marien_objs PRIVATE
  "$<$<COMPILE_LANGUAGE:C>:${LEAN_PREFIX}/include>"
  "$<$<COMPILE_LANGUAGE:CXX>:${LADYBUG_SRC}/src/include;${LADYBUG_GEN}/src/include;${LADYBUG_SRC}/third_party/fastpfor;${LADYBUG_SRC}/third_party/alp/include>")

set(EXTENSION "${CMAKE_BINARY_DIR}/libmarien.lbug_extension")
add_custom_command(OUTPUT "${EXTENSION}"
  COMMAND "${ROOT}/scripts/link-extension.sh" "${EXTENSION}" ${LINK_MODE}
    "${CMAKE_CURRENT_SOURCE_DIR}/exports" "${MARIEN_A}" -- $<TARGET_OBJECTS:marien_objs> "${ELPI_A}"
  # the object files themselves, so a changed source relinks (the target alone does not)
  DEPENDS marien_objs $<TARGET_OBJECTS:marien_objs> lean_archives "${MARIEN_A}" "${ELPI_A}"
    "${CMAKE_CURRENT_SOURCE_DIR}/exports.txt" "${CMAKE_CURRENT_SOURCE_DIR}/exports.map"
  COMMAND_EXPAND_LISTS VERBATIM)
add_custom_target(extension ALL DEPENDS "${EXTENSION}")
