#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPRODUCER_DIR="$PACKAGE_ROOT/Tools/Reproducer"
SOURCE_MANIFEST="${FILTER_ASSETS_SOURCE_MANIFEST:-$PACKAGE_ROOT/filter-sources.json}"
OUTPUT_DIR="${FILTER_ASSETS_OUTPUT_DIR:-$PACKAGE_ROOT/reproduced}"
WORK_DIR="${FILTER_ASSETS_REPRODUCER_WORK_DIR:-$OUTPUT_DIR/.reproducer-work}"
MAX_RULES_PER_CHUNK="${BLOCKERKIT_MAX_RULES_PER_CHUNK:-3000}"
JSON_DIR="$WORK_DIR/filter-json"
REPORT_DIR="$WORK_DIR/reports"
SOURCE_DIR="$WORK_DIR/sources"
RESOURCE_DIR="$OUTPUT_DIR/Sources/FilterAssets/Resources/AdBlock"
PACKAGE_VERSION="${FILTER_ASSETS_VERSION:-}"

if [ -z "$PACKAGE_VERSION" ] && [ -f "$PACKAGE_ROOT/manifest.json" ]; then
  PACKAGE_VERSION="$(plutil -extract package.version raw "$PACKAGE_ROOT/manifest.json")"
fi

if [ -z "$PACKAGE_VERSION" ]; then
  echo "Error: FILTER_ASSETS_VERSION is required when generating a new FilterAssets release." >&2
  exit 1
fi

if [ ! -f "$SOURCE_MANIFEST" ]; then
  echo "Error: source manifest not found: $SOURCE_MANIFEST" >&2
  exit 1
fi

"$SCRIPT_DIR/validate-blockerkit-sdk.sh" "$REPRODUCER_DIR"

rm -rf "$WORK_DIR" "$RESOURCE_DIR"
mkdir -p "$JSON_DIR" "$REPORT_DIR" "$SOURCE_DIR" "$RESOURCE_DIR"

PLAN_FILE="$WORK_DIR/source-plan.tsv"
swift run --disable-sandbox --package-path "$REPRODUCER_DIR" filter-assets-reproducer source-plan \
  --source-manifest "$SOURCE_MANIFEST" > "$PLAN_FILE"
BLOCKERKIT_SDK_REQUIRE_CHECKOUT=1 \
  "$SCRIPT_DIR/validate-blockerkit-sdk.sh" "$REPRODUCER_DIR"

while IFS=$'\t' read -r source_id archive_url included_directory output_prefix; do
  archive_file="$WORK_DIR/$source_id.zip"
  extracted_root="$SOURCE_DIR/$source_id"
  if [ ! -d "$extracted_root" ]; then
    extract_dir="$WORK_DIR/extract-$source_id"
    mkdir -p "$extract_dir"
    curl -fL -o "$archive_file" "$archive_url"
    unzip -q "$archive_file" -d "$extract_dir"
    top_level_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
    if [ -z "$top_level_dir" ]; then
      echo "Error: archive did not contain a top-level directory: $archive_url" >&2
      exit 1
    fi
    mv "$top_level_dir" "$extracted_root"
  fi

  input_dir="$extracted_root/$included_directory"
  if [ ! -d "$input_dir" ]; then
    echo "Error: included directory not found: $source_id/$included_directory" >&2
    exit 1
  fi
  swift run --disable-sandbox --package-path "$REPRODUCER_DIR" filter-assets-reproducer convert-adblock \
    --input-dir "$input_dir" \
    --output-dir "$JSON_DIR" \
    --output-prefix "$output_prefix" \
    --report-dir "$REPORT_DIR" \
    --max-rules-per-chunk "$MAX_RULES_PER_CHUNK"
done < "$PLAN_FILE"

swift run --disable-sandbox --package-path "$REPRODUCER_DIR" filter-assets-reproducer validate-content-rules \
  --input-dir "$JSON_DIR"

swift run --disable-sandbox --package-path "$REPRODUCER_DIR" filter-assets-reproducer compile-content-rules \
  --input-dir "$JSON_DIR" \
  --output-dir "$RESOURCE_DIR"

REPRODUCER_REVISION="$({
  find "$REPRODUCER_DIR" -type f \( -name '*.swift' -o -name 'Package.resolved' \)
  printf '%s\n' "$SCRIPT_DIR/reproduce.sh" "$SCRIPT_DIR/verify.sh" "$SCRIPT_DIR/validate-blockerkit-sdk.sh"
} | sort | while IFS= read -r file; do
    shasum -a 256 "$file" | awk '{print $1}'
  done | shasum -a 256 | awk '{print $1}')"
BLOCKERKIT_PACKAGE_MANIFEST="$REPRODUCER_DIR/.build/checkouts/BlockerKitSDK/Package.swift"
BLOCKERKIT_BINARY_ARTIFACT_CHECKSUM="$(sed -n 's/.*checksum: "\([0-9a-f]*\)".*/\1/p' "$BLOCKERKIT_PACKAGE_MANIFEST" | head -n 1)"
if [ -z "$BLOCKERKIT_BINARY_ARTIFACT_CHECKSUM" ]; then
  echo "Error: BlockerKitSDK binary artifact checksum was not found." >&2
  exit 1
fi

swift run --disable-sandbox --package-path "$REPRODUCER_DIR" filter-assets-reproducer generate-public-metadata \
  --source-manifest "$SOURCE_MANIFEST" \
  --resources-dir "$RESOURCE_DIR" \
  --report-dir "$REPORT_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --package-name FilterAssets \
  --package-version "$PACKAGE_VERSION" \
  --package-resolved "$REPRODUCER_DIR/Package.resolved" \
  --reproducer-revision "$REPRODUCER_REVISION" \
  --compiler-binary-artifact-checksum "$BLOCKERKIT_BINARY_ARTIFACT_CHECKSUM" \
  --execution-command "./Scripts/reproduce.sh"

first_license="$(find "$SOURCE_DIR" -mindepth 2 -maxdepth 2 -type f -name LICENSE | sort | head -n 1)"
if [ -n "$first_license" ]; then
  cp "$first_license" "$OUTPUT_DIR/LICENSE"
fi

rm -rf "$WORK_DIR"
echo "FilterAssets reproduced in $OUTPUT_DIR"
