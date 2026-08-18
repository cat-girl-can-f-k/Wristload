if(NOT DEFINED SOURCE OR SOURCE STREQUAL "")
  message(FATAL_ERROR "SOURCE must name the TUI native bridge source.")
endif()
if(NOT EXISTS "${SOURCE}")
  message(FATAL_ERROR "Native bridge source does not exist: ${SOURCE}")
endif()

file(READ "${SOURCE}" _source)
if(NOT DEFINED IDENTITY_HEADER OR IDENTITY_HEADER STREQUAL "" OR NOT EXISTS "${IDENTITY_HEADER}")
  message(FATAL_ERROR "IDENTITY_HEADER must name the native identity matching header.")
endif()
file(READ "${IDENTITY_HEADER}" _identity_header)
string(APPEND _source "\n${_identity_header}")

# pair.start must use the public directed Classic pairing route. Keep these
# checks source-level so selector-based regressions are caught before a user
# reaches the TUI.
foreach(_required_marker IN ITEMS
    "deviceWithAddressString"
    "pairWithDevice"
    "beginSystemPairingForDevice"
    "identity_candidate_address_mismatch"
    "identity_name_mismatch"
    "pairing_start_failed"
    "directedExactAddress"
    "directed_exact_address_name_unavailable"
    "WearableIdentityDeviceMatchMode"
    "candidateAllowsDirectedExactAddress")
  string(FIND "${_source}" "${_required_marker}" _marker_position)
  if(_marker_position EQUAL -1)
    message(FATAL_ERROR
      "Direct Classic pairing contract is missing required marker: ${_required_marker}"
    )
  endif()
endforeach()

# The address-only identity exception must be granted by identity.resolve and
# consumed from the in-memory candidate cache. Persisted mappings are built
# only after explicitly removing the session-only permission field.
foreach(_session_only_marker IN ITEMS
    "rawDirectedExactAddress = command[@\"directedExactAddress\"]"
    "if (directedExactAddress) candidateRecord[@\"directedExactAddress\"] = @YES"
    "operation.directedExactAddress = [self candidateAllowsDirectedExactAddress:candidate addressKey:key]"
    "directedExactAddress = [self candidateAllowsDirectedExactAddress:candidate addressKey:key]"
    "[confirmed removeObjectForKey:@\"directedExactAddress\"]")
  string(FIND "${_source}" "${_session_only_marker}" _marker_position)
  if(_marker_position EQUAL -1)
    message(FATAL_ERROR
      "Direct pairing session-only identity contract is missing marker: ${_session_only_marker}"
    )
  endif()
endforeach()

# No IOBluetoothUI selector is permitted anywhere in the bridge. PIN and
# numeric-comparison confirmation remain handled by the pairing delegate.
foreach(_forbidden_marker IN ITEMS
    "IOBluetoothDeviceSelectorController"
    "EnsureIOBluetoothUILoaded"
    "presentSelectorForPairingOperation"
    "selectorOpening"
    "selectorClosed"
    "IOBluetoothUI")
  string(FIND "${_source}" "${_forbidden_marker}" _marker_position)
  if(NOT _marker_position EQUAL -1)
    message(FATAL_ERROR
      "Direct Classic pairing contract forbids selector marker: ${_forbidden_marker}"
    )
  endif()
endforeach()

# Restrict the fallback audit to the pair.start implementation. Other bridge
# operations may list paired devices; pair.start must only use the cached
# identity binding and the exact-address direct lookup. String offsets avoid
# relying on regex cross-line semantics across CMake versions.
set(_start_signature "- (void)startPairing:(NSDictionary *)command requestID:(NSString *)requestID {")
set(_end_signature "- (void)cancelPairing:(NSDictionary *)command requestID:(NSString *)requestID {")
string(FIND "${_source}" "${_start_signature}" _start_offset)
string(FIND "${_source}" "${_end_signature}" _end_offset)
if(_start_offset EQUAL -1 OR _end_offset EQUAL -1 OR _end_offset LESS _start_offset)
  message(FATAL_ERROR "Could not isolate the startPairing implementation for fallback auditing.")
endif()
math(EXPR _start_length "${_end_offset} - ${_start_offset}")
string(SUBSTRING "${_source}" ${_start_offset} ${_start_length} _start_pairing_block)

foreach(_required_start_marker IN ITEMS
    "candidate_address_required"
    "identity_candidate_address_mismatch"
    "directDeviceForIdentity:key"
    "identityNameMatchModeForDevice:direct"
    "directedExactAddress:operation.directedExactAddress"
    "beginSystemPairingForDevice:direct operation:operation")
  string(FIND "${_start_pairing_block}" "${_required_start_marker}" _marker_position)
  if(_marker_position EQUAL -1)
    message(FATAL_ERROR
      "startPairing is missing required directed-pairing check: ${_required_start_marker}"
    )
  endif()
endforeach()

foreach(_forbidden_fallback IN ITEMS
    "pairedDevices"
    "IOBluetoothDeviceSelectorController"
    "presentSelectorForPairingOperation")
  string(FIND "${_start_pairing_block}" "${_forbidden_fallback}" _marker_position)
  if(NOT _marker_position EQUAL -1)
    message(FATAL_ERROR
      "startPairing contains a prohibited fallback: ${_forbidden_fallback}"
    )
  endif()
endforeach()

# identity.resolve may give pair.start an unresolved exact-address binding so
# that macOS can initiate system pairing. It must not commit the new candidate
# before rejecting conflicts with persisted confirmed/provisional mappings: an
# error on either conflict must leave the prior cache entry untouched.
set(_resolve_signature "- (void)resolveIdentity:(NSDictionary *)command requestID:(NSString *)requestID {")
set(_resolve_end_signature "- (void)emitPairingStage:(NSString *)stage")
string(FIND "${_source}" "${_resolve_signature}" _resolve_offset)
if(_resolve_offset EQUAL -1)
  message(FATAL_ERROR "Could not isolate resolveIdentity for transactional cache auditing.")
endif()
string(SUBSTRING "${_source}" ${_resolve_offset} -1 _resolve_tail)
string(FIND "${_resolve_tail}" "${_resolve_end_signature}" _resolve_tail_end_offset)
if(_resolve_tail_end_offset EQUAL -1)
  message(FATAL_ERROR "Could not find the end of resolveIdentity for transactional cache auditing.")
endif()
string(SUBSTRING "${_resolve_tail}" 0 ${_resolve_tail_end_offset} _resolve_block)
string(FIND "${_resolve_block}" "NSDictionary *confirmed = self.confirmedIdentityMappings[candidateID];" _confirmed_mapping_offset)
string(FIND "${_resolve_block}" "NSDictionary *provisional = self.provisionalIdentityMappings[candidateID];" _provisional_mapping_offset)
string(FIND "${_resolve_block}" "self.identityCandidateCache[candidateID] = candidateRecord;" _first_unresolved_cache_commit)
if(_confirmed_mapping_offset EQUAL -1 OR _provisional_mapping_offset EQUAL -1 OR
   _first_unresolved_cache_commit EQUAL -1 OR
   _first_unresolved_cache_commit LESS _confirmed_mapping_offset OR
   _first_unresolved_cache_commit LESS _provisional_mapping_offset)
  message(FATAL_ERROR
    "identity.resolve may commit an unresolved candidate only after confirmed/provisional address conflicts are checked."
  )
endif()
math(EXPR _first_unresolved_cache_commit_end
  "${_first_unresolved_cache_commit} + 1"
)
string(SUBSTRING "${_resolve_block}" ${_first_unresolved_cache_commit_end} -1 _after_first_unresolved_cache_commit)
string(FIND "${_after_first_unresolved_cache_commit}"
  "self.identityCandidateCache[candidateID] = candidateRecord;"
  _second_unresolved_cache_commit
)
if(_second_unresolved_cache_commit EQUAL -1)
  message(FATAL_ERROR
    "identity.resolve must retain the current request on both direct and scan unresolved paths."
  )
endif()

# A follow-up resolve is a new authorization transaction. Its first action
# after reading candidateId/advertisedName must revoke a prior session-only
# exact-address grant, even when later request validation fails.
string(FIND "${_resolve_block}"
  "NSDictionary *cachedCandidate = [candidateID isKindOfClass:NSString.class] ? [self identityCandidate:candidateID] : nil;"
  _grant_lookup_offset
)
string(FIND "${_resolve_block}"
  "[revokedCandidate removeObjectForKey:@\"directedExactAddress\"]"
  _grant_revoke_offset
)
string(FIND "${_resolve_block}"
  "if (![candidateID isKindOfClass:NSString.class] || candidateID.length == 0"
  _initial_validation_offset
)
if(_grant_lookup_offset EQUAL -1 OR _grant_revoke_offset EQUAL -1 OR
   _initial_validation_offset EQUAL -1 OR
   _grant_lookup_offset GREATER _initial_validation_offset OR
   _grant_revoke_offset GREATER _initial_validation_offset)
  message(FATAL_ERROR
    "identity.resolve must revoke a stale directed-address grant before validating a new transaction."
  )
endif()

# IOBluetooth does not guarantee that pairing delegates arrive on the main
# thread. All state mutation, JSONL emission, AppKit UI, and pair replies must
# cross one main-queue trampoline before they are handled.
foreach(_pairing_thread_marker IN ITEMS
    "dispatchPairingCallbackStage"
    "dispatch_async(dispatch_get_main_queue(), handleOnMain)"
    "Pairing callbacks must be handled on main thread"
    "prepareApplicationForPrompt"
    "replyPINCode"
    "replyUserConfirmation"
    "nativeStage"
    "callbackThread")
  string(FIND "${_source}" "${_pairing_thread_marker}" _marker_position)
  if(_marker_position EQUAL -1)
    message(FATAL_ERROR
      "Direct pairing main-thread/diagnostic contract is missing marker: ${_pairing_thread_marker}"
    )
  endif()
endforeach()
