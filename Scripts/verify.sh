#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${FILTER_ASSETS_OUTPUT_DIR:-$PACKAGE_ROOT/reproduced}"
CHECKSUM_FILE="${FILTER_ASSETS_CHECKSUM_FILE:-$PACKAGE_ROOT/checksums.sha256}"
cd "$OUTPUT_DIR"
shasum -a 256 -c "$CHECKSUM_FILE"
