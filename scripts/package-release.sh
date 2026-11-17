#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path="${2:-$PWD/build/Meeting Intelligence.app}"
if [[ ! -d "$app_path" ]]; then
  print -u2 'Build the app first: ./scripts/build-app.sh release'
  exit 1
fi
codesign --verify --strict "$app_path"
python3 scripts/verify-app.py "$app_path"
app_path="${app_path:A}"
if ! command -v node >/dev/null || [[ ! -d scripts/dmg/node_modules/appdmg ]]; then
  print -u2 'Packaging requires Node.js 24 and npm ci --prefix scripts/dmg.'
  exit 1
fi
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
edition="$(/usr/libexec/PlistBuddy -c 'Print :MIBuildEdition' "$app_path/Contents/Info.plist")"
suffix=""
if [[ "$edition" == compatibility ]]; then suffix="-macos15-whisper"; fi
archive="Meeting-Intelligence-$version-macos-$arch$suffix.zip"
disk_image="Meeting-Intelligence-$version-macos-$arch$suffix.dmg"
staging="$(mktemp -d "${TMPDIR:-/tmp}/meeting-release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app_path" "$staging/Meeting Intelligence.app"
cp LICENSE README.md "$staging/"
ditto -c -k --sequesterRsrc "$staging" "$output_dir/$archive"
mkdir "$staging/.Documentation"
cp LICENSE README.md "$staging/.Documentation/"
node scripts/dmg/create-installer.mjs "$staging/Meeting Intelligence.app" \
  "$output_dir/$disk_image" "$staging/.Documentation"
hdiutil verify "$output_dir/$disk_image"
python3 scripts/verify-dmg.py "$output_dir/$disk_image" "$version" "$arch"
(cd "$output_dir" && \
  shasum -a 256 "$archive" > "$archive.sha256" && \
  shasum -a 256 "$disk_image" > "$disk_image.sha256")
print "Packaged $output_dir/$archive"
print "Packaged $output_dir/$disk_image"
