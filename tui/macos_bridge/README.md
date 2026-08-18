# macOS Bluetooth bridge protocol v1

`wearable_macos_bridge` is a macOS-only JSON Lines helper for classic Bluetooth inquiry, directed pairing, SDP, and RFCOMM. It does not implement the Wristload installation protocol: the long-lived Dart facade owns the write FIFO, SPP/Mass acknowledgements, and device-install state. stderr is diagnostics only; stdout contains exactly one complete JSON object plus a newline per event.

## Build and package

Prerequisites: macOS, Xcode Command Line Tools, CMake, and the Dart SDK for the enclosing TUI. The bridge itself does not need Flutter.

From `tui/macos_bridge`, use the normal local-development build:

```sh
./scripts/package_bundle.sh --ad-hoc
```

The script configures CMake, builds the bundle, runs hardware-free CTest checks, stages the `.app`, applies an ad-hoc signature, and verifies the signed artifact. To compile and run native checks without packaging:

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

For the complete TUI check, return to `tui/` and run:

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
dart test
```

These commands do not initiate pairing, an RFCOMM connection, or a device protocol exchange.

The executable is `build/wearable_macos_bridge` and links `Foundation.framework`, `IOBluetooth.framework`, and `IOKit.framework`. Xcode command-line tools are required. It is classic Bluetooth / RFCOMM, not BLE GATT.

## Session and identifiers

Keep one helper process alive while scanning or connected. Every parseable command requires a non-empty string `requestId`; every command response/error returns that ID. Begin with `hello`; its `helperSessionId` identifies this process instance. The Dart facade must generate unique `scanId` and `connectionId` values, filter events to its current IDs, and treat stdout parse failure or process exit as a terminal transport failure.

Bluetooth addresses accept `AA-BB-CC-DD-EE-FF`, `AA:BB:CC:DD:EE:FF`, and `AABBCCDDEEFF`. Events always use a macOS display `address` with hyphens plus canonical unseparated uppercase `addressKey`. Never derive a classic address from a BLE UUID.

## Commands

```json
{"command":"hello","requestId":"r-1"}
{"command":"paired.list","requestId":"r-2"}
{"command":"scan.start","requestId":"r-3","scanId":"scan-1","duration":10}
{"command":"scan.stop","requestId":"r-4","scanId":"scan-1"}
{"command":"identity.resolve","requestId":"r-id","candidateId":"candidate-1","advertisedName":"Band","address":"AA-BB-CC-DD-EE-FF"}
{"command":"pair.start","requestId":"r-pair","pairingId":"pair-1","candidateId":"candidate-1","advertisedName":"Band","address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF"}
{"command":"connect","requestId":"r-5","connectionId":"conn-1","address":"AA-BB-CC-DD-EE-FF","serviceUuid":"1101"}
{"command":"serial.probe","requestId":"r-probe","address":"AA-BB-CC-DD-EE-FF","durationMs":5000}
{"command":"write","requestId":"r-6","connectionId":"conn-1","base64":"AQID"}
{"command":"disconnect","requestId":"r-7","connectionId":"conn-1"}
```

`serviceUuid` accepts 16-, 32-, or 128-bit SDP UUIDs. `connect` always performs SDP then dynamically obtains the RFCOMM channel; no channel number is hard-coded. A write's decoded payload is limited to 256 KiB. The bridge splits it by RFCOMM MTU with `writeSync`; `write.done` means the data reached the RFCOMM transport, not that the device protocol acknowledged it or that installation succeeded. The Dart side must serialize writes in one FIFO.

`pair.start` is directed: it requires the exact candidate binding previously created by `identity.resolve`, resolves only that Classic MAC with `IOBluetoothDevice deviceWithAddressString:`, rechecks the MAC and compatible device name, then starts `IOBluetoothDevicePair`. It never opens `IOBluetoothDeviceSelectorController` and never falls back to name-only or `pairedDevices` selection. macOS may still require PIN or numeric-comparison approval; those are pairing-security callbacks, not a device selector. A successful `pair.done` reports `identityState: provisional`; it does not prove RFCOMM availability or Xiaomi authentication.

`serial.probe` is a diagnostics-only command and is intentionally separate from `connect`. It resolves exactly one live `/dev/cu.*` endpoint by matching the requested six-byte classic MAC against the IORegistry device `BD_ADDR`/`BTAddress`, verifies the character device before and after opening it, then opens it with `O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW` and waits for passive input for at most five seconds. It never calls pairing APIs, changes termios, writes bytes, or infers an endpoint from a display name. `serial.probe.done` always reports `writes: 0`; opening it is not proof of a Xiaomi business protocol channel or bidirectional transport.

## Events

```json
{"event":"hello.done","requestId":"r-1","protocolVersion":1,"helperSessionId":"..."}
{"event":"paired.list.done","requestId":"r-2","devices":[{"address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF","name":"Band","paired":true}]}
{"event":"scan.started","requestId":"r-3","scanId":"scan-1"}
{"event":"device","scanId":"scan-1","address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF","source":"inquiry","paired":true}
{"event":"scan.stop.done","requestId":"r-4","scanId":"scan-1"}
{"event":"scan.finished","scanId":"scan-1","reason":"stopped"}
{"event":"pairing.stage","pairingId":"pair-1","candidateId":"candidate-1","stage":"pairingStarted"}
{"event":"pair.done","requestId":"r-pair","pairingId":"pair-1","candidateId":"candidate-1","identityState":"provisional","address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF","name":"Band","paired":true}
{"event":"connect.done","requestId":"r-5","connectionId":"conn-1","address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF","channel":1,"mtu":990}
{"event":"serial.probe.done","requestId":"r-probe","transport":"serial-rfcomm","addressKey":"AABBCCDDEEFF","endpoint":"cu.Band","outcome":"opened","writes":0,"rxBytes":0,"closedReason":"timeout"}
{"event":"write.done","requestId":"r-6","connectionId":"conn-1","byteCount":3}
{"event":"data","connectionId":"conn-1","base64":"AQID"}
{"event":"closed","connectionId":"conn-1","address":"AA-BB-CC-DD-EE-FF","addressKey":"AABBCCDDEEFF","reason":"local"}
{"event":"disconnect.done","requestId":"r-7","connectionId":"conn-1"}
{"event":"error","requestId":"r-5","connectionId":"conn-1","code":"rfcomm_open_failed","message":"..."}
```

For each accepted `connectionId`, `closed` is emitted once with `reason` `local`, `remote`, or `error`. A disconnect during pending SDP explicitly terminates that attempt with `closed(local)` and `disconnect.done`, then installs an address-scoped SDP drain barrier. Until the old `sdpQueryComplete` callback arrives, a new connect for that same address returns `sdp_drain_required`; the stale callback only clears the barrier and never advances a replacement attempt. If macOS never delivers the old callback, that address remains blocked until the helper/TUI is restarted; Dart currently has no automatic helper restart.

Stale RFCOMM open callbacks are filtered by channel object identity and `attemptGeneration`; a stale channel is closed and cannot emit `connect.done`, `data`, or `closed` for a newer attempt. Local close emits `closed` before `disconnect.done`. Scan completion is always represented by `scan.finished` with `completed`, `stopped`, or `failed`.

On stdin EOF the bridge performs a best-effort stop/close and exits. macOS may require Bluetooth permission and a paired or in-range device before SDP/RFCOMM can succeed.
