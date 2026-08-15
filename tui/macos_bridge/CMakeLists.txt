cmake_minimum_required(VERSION 3.20)

project(wearable_macos_bridge LANGUAGES OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "wearable_macos_bridge is macOS-only")
endif()

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)

add_executable(wearable_macos_bridge main.mm)
target_compile_options(wearable_macos_bridge PRIVATE -fobjc-arc)
target_link_libraries(wearable_macos_bridge PRIVATE
  "-framework Foundation"
  "-framework IOBluetooth"
  "-framework IOKit"
)
