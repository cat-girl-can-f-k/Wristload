if(NOT DEFINED BUNDLE OR BUNDLE STREQUAL "")
  message(FATAL_ERROR "BUNDLE must name the generated macOS app bundle.")
endif()

foreach(_required_variable
    EXPECTED_BUNDLE_IDENTIFIER
    EXPECTED_EXECUTABLE
    EXPECTED_BLUETOOTH_USAGE_DESCRIPTION)
  if(NOT DEFINED ${_required_variable} OR "${${_required_variable}}" STREQUAL "")
    message(FATAL_ERROR "${_required_variable} must be provided.")
  endif()
endforeach()

set(_contents "${BUNDLE}/Contents")
set(_plist "${_contents}/Info.plist")
set(_executable "${_contents}/MacOS/${EXPECTED_EXECUTABLE}")

if(NOT IS_DIRECTORY "${BUNDLE}")
  message(FATAL_ERROR "Bundle directory does not exist: ${BUNDLE}")
endif()
if(NOT EXISTS "${_plist}")
  message(FATAL_ERROR "Bundle Info.plist does not exist: ${_plist}")
endif()
if(NOT EXISTS "${_executable}")
  message(FATAL_ERROR "Bundle executable does not exist: ${_executable}")
endif()

execute_process(
  COMMAND /usr/bin/plutil -lint "${_plist}"
  RESULT_VARIABLE _plutil_result
  OUTPUT_VARIABLE _plutil_stdout
  ERROR_VARIABLE _plutil_stderr
)
if(NOT _plutil_result EQUAL 0)
  message(FATAL_ERROR "Invalid Info.plist: ${_plutil_stdout}${_plutil_stderr}")
endif()

function(read_plist_value key out_var)
  execute_process(
    COMMAND /usr/libexec/PlistBuddy -c "Print :${key}" "${_plist}"
    RESULT_VARIABLE _result
    OUTPUT_VARIABLE _value
    ERROR_VARIABLE _error
  )
  if(NOT _result EQUAL 0)
    message(FATAL_ERROR "Could not read ${key} from Info.plist: ${_error}")
  endif()
  string(STRIP "${_value}" _value)
  set(${out_var} "${_value}" PARENT_SCOPE)
endfunction()

read_plist_value("CFBundleIdentifier" _bundle_identifier)
read_plist_value("CFBundleExecutable" _bundle_executable)
read_plist_value("CFBundlePackageType" _package_type)
read_plist_value("NSBluetoothAlwaysUsageDescription" _bluetooth_usage)

if(NOT "${_bundle_identifier}" STREQUAL "${EXPECTED_BUNDLE_IDENTIFIER}")
  message(FATAL_ERROR
    "CFBundleIdentifier is ${_bundle_identifier}, expected ${EXPECTED_BUNDLE_IDENTIFIER}"
  )
endif()
if(NOT "${_bundle_executable}" STREQUAL "${EXPECTED_EXECUTABLE}")
  message(FATAL_ERROR
    "CFBundleExecutable is ${_bundle_executable}, expected ${EXPECTED_EXECUTABLE}"
  )
endif()
if(NOT "${_package_type}" STREQUAL "APPL")
  message(FATAL_ERROR "CFBundlePackageType is ${_package_type}, expected APPL")
endif()
if(NOT "${_bluetooth_usage}" STREQUAL "${EXPECTED_BLUETOOTH_USAGE_DESCRIPTION}")
  message(FATAL_ERROR "NSBluetoothAlwaysUsageDescription does not match the packaged policy text")
endif()

foreach(_nested_code_directory Frameworks PlugIns XPCServices)
  set(_candidate "${_contents}/${_nested_code_directory}")
  if(IS_DIRECTORY "${_candidate}")
    file(GLOB _nested_entries "${_candidate}/*")
    if(_nested_entries)
      message(FATAL_ERROR
        "TUI bridge bundle unexpectedly contains nested code in ${_nested_code_directory}: ${_nested_entries}"
      )
    endif()
  endif()
endforeach()
