#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path="$PWD/build/Meeting Intelligence.app"
if [[ ! -d "$app_path" ]]; then
  print -u2 'Build the app first: ./scripts/build-app.sh release'
  exit 1
fi
codesign --verify --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Expected an app version in X.Y.Z format.'
  exit 1
fi
arch="$(uname -m)"
if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
  print -u2 'Unsupported macOS architecture.'
  exit 1
fi
output_dir="${1:-$PWD/dist}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
archive="Meeting-Intelligence-$version-macos-$arch.zip"
staging="$(mktemp -d "${TMPDIR:-/tmp}/meeting-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app_path" "$staging/Meeting Intelligence.app"
cp LICENSE README.md "$staging/"
ditto -c -k --sequesterRsrc "$staging" "$output_dir/$archive"
(cd "$output_dir" && shasum -a 256 "$archive" > "$archive.sha256")
print "Packaged $output_dir/$archive"
