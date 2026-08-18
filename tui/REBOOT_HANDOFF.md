# Wristload TUI Restart Handoff

## Pause State

- This handoff was written immediately before a host restart.
- The repository is intentionally dirty. Preserve all existing changes; do not run git reset, git clean, git checkout, or a broad overwrite.
- No commit or stash was created because the worktree contains concurrent and user-owned changes.
- Do not reuse a prior helper PID, FIFO, Terminal session, or /private/tmp probe directory after restart.

## Standalone TUI Boundary

- Production path: tui/bin/wristload_tui.dart -> UiNextShell -> TuiApplication -> MacOsTuiBackendAdapter -> TuiProtocolBackend plus TuiJsonLineMacBluetoothTransport -> TUI-owned signed wearable_macos_bridge.app -> IOBluetooth Classic SDP/RFCOMM.
- The TUI is intentionally isolated from Flutter widgets, GUI controllers/services, GUI runtime, and GUI lifecycle.
- Enter is the connection action. Authkey input is bound to the selected Classic device before the matching connect request. Detail is a separate action.

## Current Target and Evidence

- Target device: Xiaomi Smart Band 10 Pro 5E29. Its Classic Bluetooth address is `2C:0D:CF:70:5E:29` (normalized `2C0DCF705E29`). This is the only identity that the current IOBluetooth/RFCOMM path may use for directed work.
- The supplied CoreBluetooth identifier is a BLE-layer identity. It must not be converted, truncated, or used as a Classic/RFCOMM address.
- The native helper resolves the exact Classic address and calls `IOBluetoothDevicePair` directly. It does not open `IOBluetoothDeviceSelectorController` or fall back to a name-only chooser.
- In the latest controlled pairing observation, `IOBluetoothDevicePair.start` returned without an immediate error. For roughly 90 seconds macOS supplied no terminal, PIN, numeric-comparison, or passkey delegate callback; the helper then reported `pairing_timeout`.
- The first demonstrated failing layer is therefore `IOBluetoothDevicePair.start accepted -> terminal pairing delegate delivery/handling`. The root cause is `UNKNOWN`. Classic SDP, RFCOMM open, raw TX, raw RX, and Xiaomi protocol behavior for this 5E29 remain `UNKNOWN`.
- Older Xiaomi Smart Band 10 traces, including any SDP channel, RFCOMM, L1START, or raw TX/RX result, are historical evidence only and must not be applied to this 5E29.

## Protocol and Secret Boundary

- The official f=26 handshake permits nonce-only input. `appDeviceId` and OOB are optional, must never be synthesized from a MAC, BLE identifier, or authkey, and do not justify a pre-f=26 local failure by themselves.
- Do not print or persist authkeys, OOB values, nonces, HMACs, session keys, PINs, numeric-comparison values, or other authentication secrets in diagnostics.
- Do not claim authentication, saved-device persistence, auto-connect, installation, or log-window runtime behavior as verified until this target reaches each stage with fresh evidence.

## Changes Already Present

- TUI protocol L1START parsing and diagnostics, auth/session fencing, selected-device/authkey binding, delayed persistence until ready, and late-event cleanup were updated.
- TUI-native SDP cache-poll fallback and stale callback tombstones were added.
- Diagnostic journal and independent logs viewer support were added; raw data is redacted where it could expose authentication material.
- Targeted Dart analyzer/tests, isolation/entrypoint tests, and native bundle CTest checks had passed before this pause. Re-run only from the current tree after reboot.

## Resume Order

1. Re-read AGENTS.md and the mandatory TUI, autonomous-debugging, macOS Bluetooth transport, and APK-reference skills.
2. Inspect git status without changing or discarding anything; verify the current helper bundle signature and executable after rebuilding it.
3. Check for fresh processes only. Start a new signed helper/TUI session; do not reuse pre-restart process state.
4. Before any transport conclusion, run one user-authorized directed pairing attempt for 5E29 and collect only non-sensitive diagnostics: `pairingStartReturned`, start status, native stage, callback thread/time, sender match, `isPaired`, `isConnected`, and the timeout snapshot.
5. Only if pairing reaches a verified terminal success, continue the target-specific chain: Classic SDP -> RFCOMM open -> raw TX -> raw RX -> L1 accepted -> f=26 -> f=27 -> session.ready. Keep every unobserved layer marked `UNKNOWN`.
6. Only after real ready, test saved-device persistence, auto-connect, installation, and the independent logs window.
