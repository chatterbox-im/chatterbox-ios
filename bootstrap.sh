#!/bin/bash
# bootstrap.sh — build the Rust library and populate the Xcode project.
#
# Usage:
#   ./bootstrap.sh                        # assumes ../chatterbox is the Rust repo
#   ./bootstrap.sh --rust-repo /path/to/chatterbox
#   ./bootstrap.sh --release              # release build (default: debug)
#   ./bootstrap.sh --rust-repo /path --release
#
# After this runs, open ChatterboxiOS/ChatterboxiOS.xcodeproj in Xcode.

set -euo pipefail

RUST_REPO=""
PROFILE_FLAG=""

for arg in "$@"; do
  case "$arg" in
    --release)            PROFILE_FLAG="--release" ;;
    --rust-repo)          shift; RUST_REPO="$1" ;;
    --rust-repo=*)        RUST_REPO="${arg#*=}" ;;
  esac
done

# Locate the Rust repo
if [[ -z "$RUST_REPO" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  RUST_REPO="$(cd "$SCRIPT_DIR/../chatterbox" 2>/dev/null && pwd)" || true
fi

if [[ ! -f "$RUST_REPO/Cargo.toml" ]]; then
  echo "error: cannot find the chatterbox Rust repo."
  echo "  Pass the path explicitly: ./bootstrap.sh --rust-repo /path/to/chatterbox"
  exit 1
fi

echo "==> Rust repo: $RUST_REPO"

# Delegate to the Rust repo's build script, pointing output here
"$RUST_REPO/scripts/build_ios.sh" $PROFILE_FLAG \
  --output-dir "$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "==> Bootstrap complete."
echo "    Open ChatterboxiOS/ChatterboxiOS.xcodeproj in Xcode."
