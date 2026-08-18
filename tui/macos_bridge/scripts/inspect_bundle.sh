#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BUNDLE_IDENTIFIER="com.anemo.wristload.tui.bridge"
readonly DEFAULT_EXECUTABLE="wearable_macos_bridge"

usage() {
  cat >&2 <<'EOF'
Usage: inspect_bundle.sh --app PATH [--bundle-id ID] [--require-signature]

Checks the TUI-owned JSONL helper bundle's layout, Info.plist identity, and
Bluetooth privacy declaration. --require-signature also verifies codesign.
EOF
}

fail() {
  printf 'inspect_bundle.sh: %s\n' "$*" >&2
  exit 1
}

app=""
bundle_id="$DEFAULT_BUNDLE_IDENTIFIER"
require_signature=0

while (($#)); do
  case "$1" in
    --app)
      (($# >= 2)) || fail "--app requires a path"
      app="$2"
      shift 2
      ;;
    --bundle-id)
      (($# >= 2)) || fail "--bundle-id requires an identifier"
      bundle_id="$2"
      shift 2
      ;;
    --require-signature)
      require_signature=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$app" ]] || { usage; fail "--app is required"; }
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"

contents="$app/Contents"
plist="$contents/Info.plist"
executable="$contents/MacOS/$DEFAULT_EXECUTABLE"
[[ -d "$app" ]] || fail "bundle does not exist: $app"
[[ -f "$plist" ]] || fail "Info.plist does not exist: $plist"
[[ -x "$executable" ]] || fail "helper executable does not exist: $executable"

/usr/bin/plutil -lint "$plist" >/dev/null
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

actual_bundle_id="$(plist_value CFBundleIdentifier)"
actual_executable="$(plist_value CFBundleExecutable)"
actual_package_type="$(plist_value CFBundlePackageType)"
bluetooth_usage="$(plist_value NSBluetoothAlwaysUsageDescription)"

[[ "$actual_bundle_id" == "$bundle_id" ]] ||
  fail "CFBundleIdentifier is $actual_bundle_id, expected $bundle_id"
[[ "$actual_executable" == "$DEFAULT_EXECUTABLE" ]] ||
  fail "CFBundleExecutable is $actual_executable, expected $DEFAULT_EXECUTABLE"
[[ "$actual_package_type" == "APPL" ]] ||
  fail "CFBundlePackageType is $actual_package_type, expected APPL"
[[ -n "$bluetooth_usage" ]] ||
  fail "NSBluetoothAlwaysUsageDescription is empty"

for nested_code_directory in Frameworks PlugIns XPCServices; do
  nested_path="$contents/$nested_code_directory"
  if [[ -d "$nested_path" ]] && /usr/bin/find "$nested_path" -mindepth 1 -maxdepth 1 -print -quit | /usr/bin/grep -q .; then
    fail "unexpected nested payload in $nested_code_directory: $nested_path"
  fi
done

printf 'Bundle: %s\n' "$app"
printf 'Identifier: %s\n' "$actual_bundle_id"
printf 'Executable: %s\n' "$executable"
printf 'Bluetooth usage: %s\n' "$bluetooth_usage"
printf 'Linked libraries:\n'
/usr/bin/otool -L "$executable"

if ((require_signature)); then
  /usr/bin/codesign --verify --strict --verbose=2 "$app"
  signature_details="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)"
  signed_identifier="$(printf '%s\n' "$signature_details" | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)"
  [[ "$signed_identifier" == "$bundle_id" ]] ||
    fail "codesign identifier is $signed_identifier, expected $bundle_id"
  printf 'Signature verification: passed\n'
fi
