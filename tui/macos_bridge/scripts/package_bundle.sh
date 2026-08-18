#!/usr/bin/env bash
set -euo pipefail

readonly BUNDLE_NAME="wearable_macos_bridge.app"

usage() {
  cat >&2 <<'EOF'
Usage: package_bundle.sh [--build-dir PATH] [--stage-dir PATH]
                         [--config CONFIG] [--ad-hoc | --identity IDENTITY]
                         [--entitlements PATH] [--runtime]

Builds the TUI-owned macOS JSONL helper bundle, runs its hardware-free CTest
checks, installs it into the staging prefix, then signs and inspects it.
Ad-hoc signing is the local-development default.
EOF
}

fail() {
  printf 'package_bundle.sh: %s\n' "$*" >&2
  exit 1
}

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
build_dir="$source_dir/build-bundle"
stage_dir="$build_dir/stage"
config="Release"
signing_mode=""
identity=""
entitlements=""
use_runtime=0

while (($#)); do
  case "$1" in
    --build-dir)
      (($# >= 2)) || fail "--build-dir requires a path"
      build_dir="$2"
      shift 2
      ;;
    --stage-dir)
      (($# >= 2)) || fail "--stage-dir requires a path"
      stage_dir="$2"
      shift 2
      ;;
    --config)
      (($# >= 2)) || fail "--config requires a configuration name"
      config="$2"
      shift 2
      ;;
    --ad-hoc)
      [[ -z "$signing_mode" ]] || fail "--ad-hoc cannot be combined with --identity"
      signing_mode="ad-hoc"
      shift
      ;;
    --identity)
      (($# >= 2)) || fail "--identity requires a signing identity"
      [[ -z "$signing_mode" ]] || fail "--identity cannot be combined with --ad-hoc or repeated"
      signing_mode="identity"
      identity="$2"
      shift 2
      ;;
    --entitlements)
      (($# >= 2)) || fail "--entitlements requires a plist path"
      [[ -z "$entitlements" ]] || fail "--entitlements can only be supplied once"
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

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required"
[[ -z "$entitlements" || -f "$entitlements" ]] ||
  fail "entitlements file does not exist: $entitlements"
if ((use_runtime)) && [[ "$signing_mode" != "identity" ]]; then
  fail "--runtime requires --identity"
fi

if [[ "$signing_mode" == "identity" ]]; then
  sign_args=(--identity "$identity")
else
  sign_args=(--ad-hoc)
fi
if [[ -n "$entitlements" ]]; then
  sign_args+=(--entitlements "$entitlements")
fi
if ((use_runtime)); then
  sign_args+=(--runtime)
fi

# A moved checkout leaves absolute source paths in CMakeCache.txt. Let CMake
# discard only its cache and generated metadata in that case, preserving the
# staged app until the replacement has passed all build and test steps.
cmake_args=(
  -S "$source_dir"
  -B "$build_dir"
  "-DCMAKE_BUILD_TYPE=$config"
  -DBUILD_TESTING=ON
)
cmake_fresh=()
cache_file="$build_dir/CMakeCache.txt"
if [[ -f "$cache_file" ]]; then
  cached_source="$(sed -n 's|^CMAKE_HOME_DIRECTORY:INTERNAL=||p' "$cache_file" | head -n 1)"
  if [[ -n "$cached_source" && "$cached_source" != "$source_dir" ]]; then
    cmake_fresh=(--fresh)
  fi
fi
if ((${#cmake_fresh[@]})); then
  cmake "${cmake_fresh[@]}" "${cmake_args[@]}"
else
  cmake "${cmake_args[@]}"
fi
# CTest includes the identity-name executable in addition to bundle-level
# checks. Build the complete configured target graph before invoking it so a
# packaging run cannot fail after leaving the previously staged helper active.
cmake --build "$build_dir" --config "$config"
ctest --test-dir "$build_dir" --output-on-failure -C "$config"
cmake --install "$build_dir" --config "$config" --prefix "$stage_dir"

app="$stage_dir/$BUNDLE_NAME"
[[ -d "$app" ]] || fail "installed bundle not found at expected path: $app"
"$source_dir/scripts/sign_bundle.sh" --app "$app" "${sign_args[@]}"
"$source_dir/scripts/inspect_bundle.sh" --app "$app" --require-signature
printf 'Packaged TUI JSONL helper: %s\n' "$app"
