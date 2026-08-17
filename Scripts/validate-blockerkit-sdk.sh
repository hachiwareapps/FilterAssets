#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -eq 0 ]; then
  set -- "$PACKAGE_ROOT/Tools/Reproducer"
fi

EXPECTED_VERSION=""
EXPECTED_REVISION=""
MINIMUM_VERSION="${MINIMUM_BLOCKERKIT_SDK_VERSION:-0.7.0}"
BLOCKERKIT_SDK_URL="https://github.com/hachiwareapps/BlockerKitSDK.git"

is_semantic_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

if ! is_semantic_version "$MINIMUM_VERSION"; then
  echo "Error: MINIMUM_BLOCKERKIT_SDK_VERSION must be a stable semantic version: $MINIMUM_VERSION" >&2
  exit 1
fi

version_is_at_least() {
  local version="$1"
  local minimum="$2"
  local version_major
  local version_minor
  local version_patch
  local minimum_major
  local minimum_minor
  local minimum_patch

  IFS=. read -r version_major version_minor version_patch <<< "$version"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"

  (( version_major > minimum_major ||
     (version_major == minimum_major && version_minor > minimum_minor) ||
     (version_major == minimum_major && version_minor == minimum_minor && version_patch >= minimum_patch) ))
}

manifest_dependency_details() {
  local package_dir="$1"
  local dump_file
  local dependency_count
  local dependency_index
  local identity
  local location
  local version

  dump_file="$(mktemp "${TMPDIR:-/tmp}/BlockerKitSDK-manifest.XXXXXX")"
  if ! swift package --disable-sandbox --package-path "$package_dir" dump-package > "$dump_file"; then
    rm -f "$dump_file"
    echo "Error: failed to evaluate $package_dir/Package.swift" >&2
    exit 1
  fi

  dependency_count="$(plutil -extract dependencies raw "$dump_file")"
  for ((dependency_index = 0; dependency_index < dependency_count; dependency_index++)); do
    identity="$(plutil -extract "dependencies.$dependency_index.sourceControl.0.identity" raw "$dump_file" 2>/dev/null || true)"
    if [ "$identity" != "blockerkitsdk" ]; then
      continue
    fi

    location="$(plutil -extract "dependencies.$dependency_index.sourceControl.0.location.remote.0.urlString" raw "$dump_file")"
    version="$(plutil -extract "dependencies.$dependency_index.sourceControl.0.requirement.exact.0" raw "$dump_file" 2>/dev/null || true)"
    rm -f "$dump_file"

    if [ "$location" != "$BLOCKERKIT_SDK_URL" ]; then
      echo "Error: unexpected BlockerKitSDK URL in $package_dir/Package.swift: $location" >&2
      exit 1
    fi
    if [ -z "$version" ]; then
      echo "Error: exact BlockerKitSDK version not found in $package_dir/Package.swift" >&2
      exit 1
    fi

    printf '%s\t%s\n' "$version" "$location"
    return
  done

  rm -f "$dump_file"
  echo "Error: BlockerKitSDK dependency not found in $package_dir/Package.swift" >&2
  exit 1
}

resolved_pin_index() {
  local package_dir="$1"
  local pin_count
  local pin_index
  local identity
  local matched_index=""

  pin_count="$(plutil -extract pins raw "$package_dir/Package.resolved")"
  for ((pin_index = 0; pin_index < pin_count; pin_index++)); do
    identity="$(plutil -extract "pins.$pin_index.identity" raw "$package_dir/Package.resolved")"
    if [ "$identity" = "blockerkitsdk" ]; then
      if [ -n "$matched_index" ]; then
        echo "Error: multiple BlockerKitSDK resolved pins found in $package_dir/Package.resolved" >&2
        exit 1
      fi
      matched_index="$pin_index"
    fi
  done

  if [ -n "$matched_index" ]; then
    echo "$matched_index"
    return
  fi

  echo "Error: BlockerKitSDK resolved pin not found in $package_dir/Package.resolved" >&2
  exit 1
}

for package_dir in "$@"; do
  if [ ! -f "$package_dir/Package.swift" ] || [ ! -f "$package_dir/Package.resolved" ]; then
    echo "Error: Swift package pin files not found in $package_dir" >&2
    exit 1
  fi

  if ! manifest_sdk_details="$(manifest_dependency_details "$package_dir")"; then
    exit 1
  fi
  IFS=$'\t' read -r manifest_sdk_version manifest_sdk_location <<< "$manifest_sdk_details"
  pin_index="$(resolved_pin_index "$package_dir")"
  resolved_sdk_kind="$(plutil -extract "pins.$pin_index.kind" raw "$package_dir/Package.resolved")"
  resolved_sdk_location="$(plutil -extract "pins.$pin_index.location" raw "$package_dir/Package.resolved")"
  resolved_sdk_version="$(plutil -extract "pins.$pin_index.state.version" raw "$package_dir/Package.resolved")"
  resolved_sdk_revision="$(plutil -extract "pins.$pin_index.state.revision" raw "$package_dir/Package.resolved")"

  if [ "$resolved_sdk_kind" != "remoteSourceControl" ] || [ "$resolved_sdk_location" != "$manifest_sdk_location" ]; then
    echo "Error: BlockerKitSDK resolved source does not match the manifest in $package_dir." >&2
    echo "Manifest: $manifest_sdk_location" >&2
    echo "Resolved: $resolved_sdk_kind $resolved_sdk_location" >&2
    exit 1
  fi
  if [ "$manifest_sdk_version" != "$resolved_sdk_version" ]; then
    echo "Error: BlockerKitSDK manifest/resolved mismatch in $package_dir: $manifest_sdk_version != $resolved_sdk_version" >&2
    exit 1
  fi
  if ! is_semantic_version "$resolved_sdk_version" || ! version_is_at_least "$resolved_sdk_version" "$MINIMUM_VERSION"; then
    echo "Error: BlockerKitSDK must be $MINIMUM_VERSION or later in $package_dir: $resolved_sdk_version" >&2
    exit 1
  fi
  if ! [[ "$resolved_sdk_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: BlockerKitSDK revision must be a full lowercase Git SHA in $package_dir: $resolved_sdk_revision" >&2
    exit 1
  fi

  if [ -z "$EXPECTED_VERSION" ]; then
    EXPECTED_VERSION="$resolved_sdk_version"
    EXPECTED_REVISION="$resolved_sdk_revision"
  elif [ "$resolved_sdk_version" != "$EXPECTED_VERSION" ] || [ "$resolved_sdk_revision" != "$EXPECTED_REVISION" ]; then
    echo "Error: BlockerKitSDK pin mismatch across generation packages." >&2
    echo "Expected: $EXPECTED_VERSION ($EXPECTED_REVISION)" >&2
    echo "Actual:   $resolved_sdk_version ($resolved_sdk_revision) in $package_dir" >&2
    exit 1
  fi

  checkout_dir="$package_dir/.build/checkouts/BlockerKitSDK"
  if [ -d "$checkout_dir/.git" ]; then
    checkout_revision="$(git -C "$checkout_dir" rev-parse HEAD)"
    if [ "$checkout_revision" != "$resolved_sdk_revision" ]; then
      echo "Error: BlockerKitSDK checkout/resolved mismatch in $package_dir: $checkout_revision != $resolved_sdk_revision" >&2
      exit 1
    fi
    checkout_status="$(git -C "$checkout_dir" status --porcelain --untracked-files=all)"
    if [ -n "$checkout_status" ]; then
      echo "Error: BlockerKitSDK checkout contains uncommitted changes in $package_dir:" >&2
      printf '%s\n' "$checkout_status" >&2
      exit 1
    fi
  elif [ "${BLOCKERKIT_SDK_REQUIRE_CHECKOUT:-0}" = "1" ]; then
    echo "Error: BlockerKitSDK checkout not found in $package_dir" >&2
    exit 1
  fi

  echo "BlockerKitSDK pin verified in $package_dir: $resolved_sdk_version ($resolved_sdk_revision)"
done
