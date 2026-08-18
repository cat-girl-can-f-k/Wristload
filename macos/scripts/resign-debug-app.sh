#!/bin/zsh
# Local-development helper for the unsigned/ad-hoc macOS Debug build.
# A real Apple Development or Developer ID identity remains required for
# distribution; this only keeps local Bluetooth TCC identity stable.

emulate -L zsh
setopt errexit nounset pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
default_app="$repo_root/build/macos/Build/Products/Debug/wristload.app"
app=${1:-$default_app}
app=${app:A}
expected_bundle_id='com.anemo.wristload'
requirement='=designated => identifier "com.anemo.wristload"'

if [[ ! -d "$app" || ! -f "$app/Contents/Info.plist" ]]; then
  print -u2 "Expected a built .app bundle, got: $app"
  exit 64
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
  print -u2 "Refusing to sign unexpected bundle identifier: $bundle_id"
  exit 65
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wristload-sign.XXXXXX")
entitlements="$work_dir/entitlements.plist"
trap 'rm -rf "$work_dir"' EXIT

# Preserve the entitlements emitted by the Flutter/Xcode Debug build.
/usr/bin/codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
if [[ ! -s "$entitlements" ]]; then
  print -u2 "Could not read existing app entitlements."
  exit 66
fi

# Sign nested code before the app seal. Do not use --deep for signing: it can
# silently discard nested signing decisions. --deep is used only for validation.
while IFS= read -r -d '' nested; do
  /usr/bin/codesign --force --sign - "$nested"
done < <(
  /usr/bin/find "$app/Contents" -depth -type d \
    \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) -prune -print0
)

while IFS= read -r -d '' dylib; do
  /usr/bin/codesign --force --sign - "$dylib"
done < <(
  /usr/bin/find "$app/Contents/MacOS" -maxdepth 1 -type f -name '*.dylib' -print0
)

/usr/bin/codesign --force --sign - \
  --entitlements "$entitlements" \
  --requirements "$requirement" \
  "$app"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign -d -r- "$app" 2>&1 | /usr/bin/sed -n '/designated =>/p'
print "Local Debug signing complete for $app"
