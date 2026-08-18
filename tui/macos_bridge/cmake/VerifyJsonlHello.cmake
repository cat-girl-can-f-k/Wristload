if(NOT DEFINED HELPER OR HELPER STREQUAL "")
  message(FATAL_ERROR "HELPER must name the bundled JSONL helper executable.")
endif()

if(NOT EXISTS "${HELPER}")
  message(FATAL_ERROR "Bundled helper does not exist: ${HELPER}")
endif()

set(_input_file "${CMAKE_CURRENT_BINARY_DIR}/wearable_macos_bridge_hello.jsonl")
file(WRITE "${_input_file}" "{\"command\":\"hello\",\"requestId\":\"ctest-hello\"}\n")

execute_process(
  COMMAND "${HELPER}"
  INPUT_FILE "${_input_file}"
  RESULT_VARIABLE _result
  OUTPUT_VARIABLE _stdout
  ERROR_VARIABLE _stderr
  TIMEOUT 5
)

if(NOT _result EQUAL 0)
  message(FATAL_ERROR
    "Bundled helper hello exited with ${_result}. stderr: ${_stderr}"
  )
endif()

string(REPLACE "\r\n" "\n" _stdout "${_stdout}")
string(REPLACE "\n" ";" _lines "${_stdout}")
set(_hello_found FALSE)
foreach(_line IN LISTS _lines)
  if(_line STREQUAL "")
    continue()
  endif()

  string(JSON _event ERROR_VARIABLE _json_error GET "${_line}" event)
  if(_json_error)
    message(FATAL_ERROR "Helper stdout is not JSONL: ${_line}")
  endif()

  if(_event STREQUAL "hello.done")
    string(JSON _request_id ERROR_VARIABLE _request_error GET "${_line}" requestId)
    string(JSON _protocol_version ERROR_VARIABLE _version_error GET "${_line}" protocolVersion)
    string(JSON _session_id ERROR_VARIABLE _session_error GET "${_line}" helperSessionId)
    if(_request_error OR _version_error OR _session_error)
      message(FATAL_ERROR "hello.done is missing a required field: ${_line}")
    endif()
    if(NOT "${_request_id}" STREQUAL "ctest-hello")
      message(FATAL_ERROR "hello.done returned the wrong requestId: ${_request_id}")
    endif()
    if(NOT _protocol_version EQUAL 1)
      message(FATAL_ERROR "hello.done returned protocolVersion ${_protocol_version}, expected 1")
    endif()
    if(_session_id STREQUAL "")
      message(FATAL_ERROR "hello.done returned an empty helperSessionId")
    endif()
    set(_hello_found TRUE)
  endif()
endforeach()

if(NOT _hello_found)
  message(FATAL_ERROR "Helper did not emit hello.done. stdout: ${_stdout}")
endif()
