#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${FILTER_ASSETS_OUTPUT_DIR:-$PACKAGE_ROOT/reproduced}"
CHECKSUM_FILE="${FILTER_ASSETS_CHECKSUM_FILE:-$PACKAGE_ROOT/checksums.sha256}"
cd "$OUTPUT_DIR"
shasum -a 256 -c "$CHECKSUM_FILE"
swift run --disable-sandbox --package-path "$PACKAGE_ROOT/Tools/Reproducer" filter-assets-reproducer validate-user-script-artifacts \
  --resources-dir "$OUTPUT_DIR/Sources/FilterAssets/Resources/AdBlock" \
  --checksums-file "$CHECKSUM_FILE"
