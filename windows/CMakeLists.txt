# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(wuthering_waves_convene_gacha_analyzer LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "wuthering_waves_convene_gacha_analyzer")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# webview_windows 的 CMakeLists 用了 CMP0175（CMake ≥3.31）視為無效的
# add_custom_command(TARGET ... DEPENDS) 寫法，會跳「policy CMP0175 is not set」
# 開發者警告。把該 policy 的子目錄預設設為 OLD（沿用既有寬鬆行為）以消除噪音；
# 不影響建置產物。外掛屬 vendored 檔不手改，故在 app 端設預設讓它傳播到外掛子目錄。
set(CMAKE_POLICY_DEFAULT_CMP0175 OLD)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# === Rust (flutter_rust_bridge) ===
# Build gacha_capture_core.dll via cargokit and install it next to the exe.
# lib_name must match the Cargo.toml package name so the dll stem matches what
# the FRB Dart loader expects (ExternalLibraryLoaderConfig.stem = 'gacha_capture_core').
set(CARGOKIT_RUST_PROJECT "gacha_capture_core")
include("${CMAKE_CURRENT_SOURCE_DIR}/../rust_builder/cargokit/cmake/cargokit.cmake")
apply_cargokit(${CARGOKIT_RUST_PROJECT} ../rust ${CARGOKIT_RUST_PROJECT} "")

# === 提權攔截 helper（capture_helper.exe，獨立 cargo binary）===
# 用 WinDivert 把 KRWebView.exe 的 :443 重導向進主程式 hudsucker。需 admin（由主程式 UAC
# spawn）。建置需 WINDIVERT_PATH 指向 vendored 的 WinDivert.lib；執行期需 WinDivert.dll +
# WinDivert64.sys 在 exe 同目錄（下方 install 一併複製）。
set(CAPTURE_HELPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust_capture_helper")
set(WINDIVERT_DIR "${CAPTURE_HELPER_DIR}/windivert/x64")
set(CAPTURE_HELPER_EXE "${CAPTURE_HELPER_DIR}/target/release/capture_helper.exe")
add_custom_target(capture_helper ALL
  COMMAND ${CMAKE_COMMAND} -E env "WINDIVERT_PATH=${WINDIVERT_DIR}"
    cargo build --release --manifest-path "${CAPTURE_HELPER_DIR}/Cargo.toml"
  WORKING_DIRECTORY "${CAPTURE_HELPER_DIR}"
  COMMENT "Building capture_helper.exe (WinDivert redirect helper)"
  VERBATIM)

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Install the Rust dynamic library (gacha_capture_core.dll) built by cargokit.
install(FILES "${${CARGOKIT_RUST_PROJECT}_cargokit_lib}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Install the elevated capture helper + WinDivert runtime files next to the exe.
install(PROGRAMS "${CAPTURE_HELPER_EXE}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
install(FILES "${WINDIVERT_DIR}/WinDivert.dll" "${WINDIVERT_DIR}/WinDivert64.sys"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
