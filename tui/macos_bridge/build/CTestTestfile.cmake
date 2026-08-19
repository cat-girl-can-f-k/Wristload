# CMake generated Testfile for 
# Source directory: /Users/ikun_cxkpro/WearableInstall/tui/macos_bridge
# Build directory: /Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/build
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test([=[wearable_macos_bridge_identity_name_match]=] "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/build/wearable_macos_bridge_identity_name_match_test")
set_tests_properties([=[wearable_macos_bridge_identity_name_match]=] PROPERTIES  TIMEOUT "10" _BACKTRACE_TRIPLES "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;68;add_test;/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;0;")
add_test([=[wearable_macos_bridge_sdp_query_contract]=] "/usr/local/lib/python3.13/site-packages/cmake/data/bin/cmake" "-DSOURCE=/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/main.mm" "-P" "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/cmake/VerifySdpQueryContract.cmake")
set_tests_properties([=[wearable_macos_bridge_sdp_query_contract]=] PROPERTIES  TIMEOUT "10" _BACKTRACE_TRIPLES "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;77;add_test;/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;0;")
add_test([=[wearable_macos_bridge_bundle_jsonl_hello]=] "/usr/local/lib/python3.13/site-packages/cmake/data/bin/cmake" "-DHELPER=/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/build/wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge" "-P" "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/cmake/VerifyJsonlHello.cmake")
set_tests_properties([=[wearable_macos_bridge_bundle_jsonl_hello]=] PROPERTIES  TIMEOUT "10" _BACKTRACE_TRIPLES "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;88;add_test;/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;0;")
add_test([=[wearable_macos_bridge_bundle_layout]=] "/usr/local/lib/python3.13/site-packages/cmake/data/bin/cmake" "-DBUNDLE=/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/build/wearable_macos_bridge.app" "-DEXPECTED_BUNDLE_IDENTIFIER=com.anemo.wristload.tui.bridge" "-DEXPECTED_EXECUTABLE=wearable_macos_bridge" "-DEXPECTED_BLUETOOTH_USAGE_DESCRIPTION=Wristload TUI uses Bluetooth to discover and communicate with wearable devices you select." "-P" "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/cmake/VerifyBundleLayout.cmake")
set_tests_properties([=[wearable_macos_bridge_bundle_layout]=] PROPERTIES  TIMEOUT "10" _BACKTRACE_TRIPLES "/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;99;add_test;/Users/ikun_cxkpro/WearableInstall/tui/macos_bridge/CMakeLists.txt;0;")
