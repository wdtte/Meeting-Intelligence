#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path="${2:-$PWD/build/Meeting Intelligence.app}"
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
arch="$(lipo -archs "$app_path/Contents/MacOS/MeetingIntelligence")"
if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
  print -u2 'Expected a single arm64 or x86_64 app architecture.'
  exit 1
fi
output_dir="${1:-$PWD/dist}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
archive="Meeting-Intelligence-$version-macos-$arch.zip"
disk_image="Meeting-Intelligence-$version-macos-$arch.dmg"
staging="$(mktemp -d "${TMPDIR:-/tmp}/meeting-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app_path" "$staging/Meeting Intelligence.app"
cp LICENSE README.md "$staging/"
ditto -c -k --sequesterRsrc "$staging" "$output_dir/$archive"
ln -s /Applications "$staging/Applications"
hdiutil create -volname 'Meeting Intelligence' -srcfolder "$staging" \
  -format UDZO -fs HFS+ -ov "$output_dir/$disk_image"
hdiutil verify "$output_dir/$disk_image"
(cd "$output_dir" && \
  shasum -a 256 "$archive" > "$archive.sha256" && \
  shasum -a 256 "$disk_image" > "$disk_image.sha256")
print "Packaged $output_dir/$archive"
print "Packaged $output_dir/$disk_image"
