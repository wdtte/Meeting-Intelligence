#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 'Usage: scripts/build-summary-helper.sh [debug|release]'
  exit 2
fi
if ! command -v cargo >/dev/null; then
  print -u2 'Building the Rust summary backend requires Rust/Cargo: https://rustup.rs'
  exit 1
fi
case "$(uname -m)" in
  arm64) rust_target=aarch64-apple-darwin ;;
  x86_64) rust_target=x86_64-apple-darwin ;;
  *) print -u2 'Unsupported macOS architecture'; exit 1 ;;
esac
flags=()
if [[ "$configuration" == release ]]; then flags=(--release); fi
cargo build --locked --manifest-path Helpers/summary/Cargo.toml --target "$rust_target" "${flags[@]}"
mkdir -p build
cp "Helpers/summary/target/$rust_target/$configuration/meeting-summary" build/.meeting-summary.next
mv -f build/.meeting-summary.next build/meeting-summary
