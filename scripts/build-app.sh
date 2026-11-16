#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 'Usage: scripts/build-app.sh [debug|release]'
  exit 2
fi
./scripts/build-summary-helper.sh "$configuration"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/build/Meeting Intelligence.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Replace the executable inode instead of truncating a binary mapped by a running recording.
cp "$bin_dir/MeetingIntelligence" "$app_path/Contents/MacOS/.MeetingIntelligence.next"
mv -f "$app_path/Contents/MacOS/.MeetingIntelligence.next" "$app_path/Contents/MacOS/MeetingIntelligence"
cp "$bin_dir/meeting" "$app_path/Contents/MacOS/.meeting.next"
mv -f "$app_path/Contents/MacOS/.meeting.next" "$app_path/Contents/MacOS/meeting"
cp build/meeting-summary "$app_path/Contents/MacOS/.meeting-summary.next"
mv -f "$app_path/Contents/MacOS/.meeting-summary.next" "$app_path/Contents/MacOS/meeting-summary"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_commit="$(git rev-parse --short HEAD 2>/dev/null || print uncommitted)"
/usr/libexec/PlistBuddy -c "Add :MIBuildTime string $build_time" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MICommit string $build_commit" "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp Sources/MeetingCore/Resources/TranscriptExport.html "$app_path/Contents/Resources/TranscriptExport.html"
# A stable signing identity lets Keychain recognize subsequent local builds.
# An explicit identity wins; auto-select only an unambiguous Apple identity.
signing_identity="${MEETING_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  identities=(${(f)"$(security find-identity -v -p codesigning | sed -nE '/"(Apple Development:|Developer ID Application:)/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) .*/\1/p')"})
  if (( ${#identities} == 1 )) && [[ -n "${identities[1]}" ]]; then
    signing_identity="${identities[1]}"
  else
    signing_identity="-"
    print 'No unique signing identity; using ad-hoc signing. Keychain may ask again after rebuilding.'
  fi
fi
codesign --force --sign "$signing_identity" "$app_path/Contents/MacOS/meeting-summary"
codesign --force --sign "$signing_identity" "$app_path/Contents/MacOS/meeting"
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --strict "$app_path"
# Refresh only this app's registration, leaving the user's Dock and other apps alone.
touch "$app_path"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$app_path"
fi
print "Built $app_path"
