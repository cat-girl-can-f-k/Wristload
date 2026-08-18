if(NOT DEFINED SOURCE OR SOURCE STREQUAL "")
  message(FATAL_ERROR "SOURCE must name the TUI native bridge source.")
endif()
if(NOT EXISTS "${SOURCE}")
  message(FATAL_ERROR "Native bridge source does not exist: ${SOURCE}")
endif()

file(READ "${SOURCE}" _source)

# The GUI behavior contract is a complete SDP query. Endpoint selection may
# filter returned records by UUID, but the native invocation must not use the
# filtered UUID overload.
string(FIND "${_source}" "[device performSDPQuery:self.pendingSDPDelegate];" _full_query)
if(_full_query EQUAL -1)
  message(FATAL_ERROR "TUI bridge does not invoke the complete performSDPQuery: overload.")
endif()
string(FIND "${_source}" "performSDPQuery:self.pendingSDPDelegate\n                                      uuids:" _targeted_query)
if(NOT _targeted_query EQUAL -1)
  message(FATAL_ERROR "TUI bridge still contains the targeted SDP UUID overload.")
endif()

# GUI permits an exact-tuple cache-refresh fallback when IOBluetooth refreshes
# services but never delivers the terminal delegate callback. The fallback must
# remain explicitly inferred and preserve the original callback target in a
# process-lifetime tombstone before it advances endpoint selection.
string(FIND "${_source}" "sdp.cache_refresh" _cache_refresh)
string(FIND "${_source}" "completionSource:@\"delegate\"" _delegate_completion)
string(FIND "${_source}" "completionSource:@\"cache_poll\"" _cache_completion)
string(FIND "${_source}" "completionStatusInferred" _cache_inferred)
string(FIND "${_source}" "completionStatusSource" _cache_status_source)
string(FIND "${_source}" "@\"service_cache_refresh\"" _cache_status_value)
string(FIND "${_source}" "retirePendingSDPQueryToTombstoneWithKind:@\"sdp.cache_fallback.tombstone\"" _cache_tombstone)
string(FIND "${_source}" "cacheTombstoneMatches" _cache_tuple_fence)
if(_cache_refresh EQUAL -1 OR _delegate_completion EQUAL -1 OR
   _cache_completion EQUAL -1 OR _cache_inferred EQUAL -1 OR
   _cache_status_source EQUAL -1 OR _cache_status_value EQUAL -1 OR
   _cache_tombstone EQUAL -1 OR _cache_tuple_fence EQUAL -1)
  message(FATAL_ERROR "SDP cache fallback diagnostics, tombstone retention, or exact tuple fence is missing.")
endif()

# Tombstones intentionally remain for helper-process lifetime. A late native
# callback must be diagnosed and ignored, never allowed to deallocate or mutate
# a new connection attempt.
string(FIND "${_source}" "[self.retiredSDPQueries removeObjectAtIndex:index]" _retired_removal)
if(NOT _retired_removal EQUAL -1)
  message(FATAL_ERROR "SDP callback tombstones must not be removed after a late callback.")
endif()

# Keep the query kind explicit in emitted diagnostics for A/B evidence.
string(FIND "${_source}" "@\"queryKind\": @\"full\"" _full_kind)
if(_full_kind EQUAL -1)
  message(FATAL_ERROR "Full SDP query diagnostics are missing queryKind=full.")
endif()

string(FIND "${_source}" "emitConnectionDiagnostic:@\"sdp.service_record\"" _service_record_helper)
if(_service_record_helper EQUAL -1)
  message(FATAL_ERROR "SDP service-record diagnostics bypass the strict connection tuple helper.")
endif()
string(FIND "${_source}" "@\"address\": ColonAddressForKey" _drain_address)
if(_drain_address EQUAL -1)
  message(FATAL_ERROR "SDP drain diagnostics do not include the canonical display address.")
endif()
string(FIND "${_source}" "@\"endpoint\": channelStatus == kIOReturnSuccess" _record_endpoint)
if(_record_endpoint EQUAL -1)
  message(FATAL_ERROR "SDP service-record diagnostics do not expose the discovered RFCOMM endpoint.")
endif()

# The delegate entry is the first proof that IOBluetooth delivered its
# terminal callback. Preserve selector, original thread/timestamp, connection
# tuple, and bridge acceptance/rejection reasons.
string(FIND "${_source}" "sdp.callback.entered" _callback_entered)
string(FIND "${_source}" "callbackSelector\": @\"sdpQueryComplete:status:\"" _callback_selector)
string(FIND "${_source}" "callbackThread\": callbackThread" _callback_thread)
string(FIND "${_source}" "callbackTimestampMs\": @(callbackAtMillis)" _callback_timestamp)
string(FIND "${_source}" "sdp.callback.accepted" _callback_accepted)
string(FIND "${_source}" "sdp.callback.rejected" _callback_rejected)
string(FIND "${_source}" "reason\": @\"generation_mismatch\"" _generation_rejection)
string(FIND "${_source}" "reason\": @\"device_not_pending\"" _device_rejection)
string(FIND "${_source}" "reason\": @\"no_active_connection\"" _connection_rejection)
if(_callback_entered EQUAL -1 OR _callback_selector EQUAL -1 OR
   _callback_thread EQUAL -1 OR _callback_timestamp EQUAL -1 OR
   _callback_accepted EQUAL -1 OR _callback_rejected EQUAL -1 OR
   _generation_rejection EQUAL -1 OR _device_rejection EQUAL -1 OR
   _connection_rejection EQUAL -1)
  message(FATAL_ERROR "SDP callback entry/accept/reject diagnostics are incomplete.")
endif()

# GUI allows a 30-second native connection window. Keep this strict TUI
# diagnostic window above it so a shorter timeout cannot mask the callback.
string(FIND "${_source}" "kSDPTimeoutMilliseconds = 35000" _sdp_timeout)
if(_sdp_timeout EQUAL -1)
  message(FATAL_ERROR "TUI SDP timeout must remain at least 35 seconds for strict diagnostics.")
endif()
