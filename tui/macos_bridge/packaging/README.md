# TUI macOS helper bundle

This directory packages only the standalone native JSONL helper. It does not
embed Flutter, import GUI code, or use the Flutter Runner lifecycle.

The packaged artifact is:

```text
wearable_macos_bridge.app
  Contents/Info.plist
  Contents/MacOS/wearable_macos_bridge
```

Its stable bundle identifier is `com.anemo.wristload.tui.bridge`. The
helper-owned `Info.plist` declares `NSBluetoothAlwaysUsageDescription`.
No sandbox entitlement is applied by default: the helper intentionally uses
IOBluetooth/IORegistry and may read `/Library/Preferences/com.apple.Bluetooth.plist`
or open an exact `/dev/cu.*` endpoint. A future sandboxed distribution must
supply its own entitlement file and prove each native access path still works.

## Local package build

```sh
./scripts/package_bundle.sh \
  --build-dir /tmp/wristload-tui-bridge-build \
  --stage-dir /tmp/wristload-tui-bridge-stage \
  --ad-hoc
```

The command configures/builds `wearable_macos_bridge_bundle`, runs the JSONL
hello and bundle-layout CTest checks, installs the `.app`, applies an explicit
ad-hoc signature, and verifies the signature and plist. For a local Apple
Development identity, replace `--ad-hoc` with:

```sh
--identity "Apple Development: Your Name (TEAMID)"
```

`--runtime` is only valid with a non-ad-hoc identity. Notarization and
Gatekeeper assessment are intentionally outside this development package path.

## Manual inspection

```sh
./scripts/inspect_bundle.sh \
  --app /tmp/wristload-tui-bridge-stage/wearable_macos_bridge.app \
  --require-signature
```

The existing development helper remains
`macos_bridge/build/wearable_macos_bridge` so no Dart path changes are needed.
When the packaged host is selected explicitly, pass its inner executable to
the TUI, never the `.app` directory:

```text
.../wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge
```

A valid bundle, signature, and JSONL hello handshake do not establish SDP,
RFCOMM, raw TX, or raw RX.
