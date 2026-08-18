#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BUNDLE_IDENTIFIER="com.anemo.wristload.tui.bridge"

usage() {
  cat >&2 <<'EOF'
Usage: sign_bundle.sh --app PATH [--ad-hoc | --identity IDENTITY]
                      [--bundle-id ID] [--entitlements PATH] [--runtime]

The default is explicit local ad-hoc signing. --identity accepts an Apple
Development or other locally installed signing identity. This script signs
only the app bundle supplied to it; it does not notarize or assess Gatekeeper.
EOF
}

fail() {
  printf 'sign_bundle.sh: %s\n' "$*" >&2
  exit 1
}

app=""
bundle_id="$DEFAULT_BUNDLE_IDENTIFIER"
identity="-"
sign_mode="ad-hoc"
entitlements=""
use_runtime=0

while (($#)); do
  case "$1" in
    --app)
      (($# >= 2)) || fail "--app requires a path"
      app="$2"
      shift 2
      ;;
    --ad-hoc)
      [[ "$sign_mode" == "ad-hoc" ]] || fail "--ad-hoc cannot be combined with --identity"
      identity="-"
      shift
      ;;
    --identity)
      (($# >= 2)) || fail "--identity requires a signing identity"
      [[ "$sign_mode" == "ad-hoc" && "$identity" == "-" ]] ||
        fail "--identity can only be supplied once"
      sign_mode="identity"
      identity="$2"
      shift 2
      ;;
    --bundle-id)
      (($# >= 2)) || fail "--bundle-id requires an identifier"
      bundle_id="$2"
      shift 2
      ;;
    --entitlements)
      (($# >= 2)) || fail "--entitlements requires a plist path"
      entitlements="$2"
      shift 2
      ;;
    --runtime)
      use_runtime=1
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
[[ -d "$app" ]] || fail "bundle does not exist: $app"
[[ -f "$app/Contents/Info.plist" ]] || fail "Info.plist does not exist in bundle"
[[ -z "$entitlements" || -f "$entitlements" ]] ||
  fail "entitlements file does not exist: $entitlements"
if ((use_runtime)) && [[ "$sign_mode" == "ad-hoc" ]]; then
  fail "--runtime requires a non-ad-hoc signing identity"
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[[ "$actual_bundle_id" == "$bundle_id" ]] ||
  fail "Info.plist identifier is $actual_bundle_id, expected $bundle_id"

codesign_args=(--force --sign "$identity" --identifier "$bundle_id")
if [[ "$sign_mode" == "ad-hoc" ]]; then
  codesign_args+=(--timestamp=none)
elif ((use_runtime)); then
  codesign_args+=(--options runtime --timestamp)
else
  codesign_args+=(--timestamp=none)
fi
if [[ -n "$entitlements" ]]; then
  codesign_args+=(--entitlements "$entitlements")
fi
codesign_args+=("$app")

# Sign only after packaging is complete; do not use --deep as a substitute
# for explicitly signing any future nested code before this outer bundle.
/usr/bin/codesign "${codesign_args[@]}"
/usr/bin/codesign --verify --strict --verbose=2 "$app"
printf 'Signed %s with %s signing.\n' "$app" "$sign_mode"
