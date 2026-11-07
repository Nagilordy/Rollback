cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "frame_video")
project(${PROJECT_NAME} LANGUAGES C CXX)

set(PLUGIN_NAME "frame_video_plugin")

find_package(PkgConfig REQUIRED)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
# The Wayland HDR layer (hdr_surface.cc): libmpv's render API on an EGL subsurface, described
# to the compositor with the colour-management protocol.
pkg_check_modules(FRAME_HDR REQUIRED IMPORTED_TARGET wayland-client wayland-egl egl mpv)
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
pkg_get_variable(WAYLAND_SCANNER wayland-scanner wayland_scanner)
if(NOT WAYLAND_SCANNER)
  find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
endif()
set(CM_XML "${WAYLAND_PROTOCOLS_DIR}/staging/color-management/color-management-v1.xml")
if(NOT EXISTS "${CM_XML}")
  message(FATAL_ERROR "frame_video: ${CM_XML} not found (wayland-protocols 1.41 or newer is needed)")
endif()
set(CM_HEADER "${CMAKE_CURRENT_BINARY_DIR}/color-management-v1-client-protocol.h")
set(CM_CODE "${CMAKE_CURRENT_BINARY_DIR}/color-management-v1-protocol.c")
add_custom_command(
  OUTPUT "${CM_HEADER}" "${CM_CODE}"
  COMMAND "${WAYLAND_SCANNER}" client-header "${CM_XML}" "${CM_HEADER}"
  COMMAND "${WAYLAND_SCANNER}" private-code "${CM_XML}" "${CM_CODE}"
  DEPENDS "${CM_XML}"
)
add_library(frame_video_hdr STATIC "hdr_surface.cc" "${CM_CODE}" "${CM_HEADER}")
set_target_properties(frame_video_hdr PROPERTIES POSITION_INDEPENDENT_CODE ON CXX_STANDARD 17)
target_include_directories(frame_video_hdr PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(frame_video_hdr PUBLIC PkgConfig::GTK PkgConfig::FRAME_HDR)

add_library(${PLUGIN_NAME} SHARED
  "frame_video_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter PkgConfig::GTK PkgConfig::X11 frame_video_hdr)

# Checking the HDR layer without Rollback: hdr_test <video> [seconds] [sdr] (not part of the app).
add_executable(frame_video_hdr_test EXCLUDE_FROM_ALL "tools/hdr_test.cc")
target_link_libraries(frame_video_hdr_test PRIVATE frame_video_hdr)

set(frame_video_bundled_libraries "" PARENT_SCOPE)
