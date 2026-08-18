cmake_minimum_required(VERSION 3.20)

project(wearable_macos_bridge VERSION 1.0.0 LANGUAGES OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "wearable_macos_bridge is macOS-only")
endif()

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)

set(WEARABLE_MACOS_BRIDGE_BUNDLE_IDENTIFIER "com.anemo.wristload.tui.bridge")
set(WEARABLE_MACOS_BRIDGE_BUNDLE_NAME "Wristload TUI Bluetooth Bridge")
set(WEARABLE_MACOS_BRIDGE_BUNDLE_BUILD_VERSION "1")
set(
  WEARABLE_MACOS_BRIDGE_BLUETOOTH_USAGE_DESCRIPTION
  "Wristload TUI uses Bluetooth to discover and communicate with wearable devices you select."
)

function(configure_wearable_macos_bridge_target target)
  target_compile_options(${target} PRIVATE -fobjc-arc)
  target_link_libraries(${target} PRIVATE
    "-framework AppKit"
    "-framework Foundation"
    "-framework IOBluetooth"
    "-framework IOKit"
  )
endfunction()

# Preserve the plain executable for the existing standalone TUI helper path.
add_executable(wearable_macos_bridge main.mm)
configure_wearable_macos_bridge_target(wearable_macos_bridge)

# This is a TUI-owned app bundle. Its nested executable deliberately keeps the
# JSONL helper name, while the bundle gives macOS a stable runtime identity.
add_executable(wearable_macos_bridge_bundle MACOSX_BUNDLE main.mm)
set_target_properties(wearable_macos_bridge_bundle PROPERTIES
  OUTPUT_NAME "wearable_macos_bridge"
  MACOSX_BUNDLE_INFO_PLIST
    "${CMAKE_CURRENT_SOURCE_DIR}/packaging/Info.plist.in"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${WEARABLE_MACOS_BRIDGE_BUNDLE_IDENTIFIER}"
  MACOSX_BUNDLE_BUNDLE_NAME "${WEARABLE_MACOS_BRIDGE_BUNDLE_NAME}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  MACOSX_BUNDLE_LONG_VERSION_STRING "${PROJECT_VERSION}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${WEARABLE_MACOS_BRIDGE_BUNDLE_BUILD_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "Copyright 2026 Wristload contributors"
)
configure_wearable_macos_bridge_target(wearable_macos_bridge_bundle)

# A MACOSX_BUNDLE target is a BUNDLE artifact, not a RUNTIME artifact. Keep
# the destination relative so callers can choose a staging prefix safely.
install(TARGETS wearable_macos_bridge_bundle
  BUNDLE DESTINATION "."
  COMPONENT TuiMacosBridge
)

include(CTest)
if(BUILD_TESTING)
  add_executable(
    wearable_macos_bridge_identity_name_match_test
    tests/identity_name_match_test.mm
  )
  target_compile_options(wearable_macos_bridge_identity_name_match_test PRIVATE -fobjc-arc)
  target_link_libraries(wearable_macos_bridge_identity_name_match_test PRIVATE
    "-framework Foundation"
  )
  add_test(
    NAME wearable_macos_bridge_identity_name_match
    COMMAND wearable_macos_bridge_identity_name_match_test
  )
  set_tests_properties(
    wearable_macos_bridge_identity_name_match
    PROPERTIES TIMEOUT 10
  )

  add_test(
    NAME wearable_macos_bridge_sdp_query_contract
    COMMAND "${CMAKE_COMMAND}"
      "-DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}/main.mm"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifySdpQueryContract.cmake"
  )
  set_tests_properties(
    wearable_macos_bridge_sdp_query_contract
    PROPERTIES TIMEOUT 10
  )

  add_test(
    NAME wearable_macos_bridge_direct_pair_contract
    COMMAND "${CMAKE_COMMAND}"
      "-DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}/main.mm"
      "-DIDENTITY_HEADER=${CMAKE_CURRENT_SOURCE_DIR}/identity_name_match.h"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyDirectPairContract.cmake"
  )
  set_tests_properties(
    wearable_macos_bridge_direct_pair_contract
    PROPERTIES TIMEOUT 10
  )

  add_test(
    NAME wearable_macos_bridge_bundle_jsonl_hello
    COMMAND "${CMAKE_COMMAND}"
      "-DHELPER=$<TARGET_FILE:wearable_macos_bridge_bundle>"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyJsonlHello.cmake"
  )
  set_tests_properties(
    wearable_macos_bridge_bundle_jsonl_hello
    PROPERTIES TIMEOUT 10
  )

  add_test(
    NAME wearable_macos_bridge_bundle_layout
    COMMAND "${CMAKE_COMMAND}"
      "-DBUNDLE=$<TARGET_BUNDLE_DIR:wearable_macos_bridge_bundle>"
      "-DEXPECTED_BUNDLE_IDENTIFIER=${WEARABLE_MACOS_BRIDGE_BUNDLE_IDENTIFIER}"
      "-DEXPECTED_EXECUTABLE=wearable_macos_bridge"
      "-DEXPECTED_BLUETOOTH_USAGE_DESCRIPTION=${WEARABLE_MACOS_BRIDGE_BLUETOOTH_USAGE_DESCRIPTION}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/VerifyBundleLayout.cmake"
  )
  set_tests_properties(
    wearable_macos_bridge_bundle_layout
    PROPERTIES TIMEOUT 10
  )
endif()
