#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 'Usage: scripts/build-app.sh [debug|release]'
  exit 2
fi
export MEETING_BUILD_EDITION="${MEETING_BUILD_EDITION:-standard}"
case "$MEETING_BUILD_EDITION" in
  standard) minimum_system=26.0; app_path="$PWD/build/Meeting Intelligence.app" ;;
  compatibility) minimum_system=15.0; app_path="$PWD/build/compatibility/Meeting Intelligence.app" ;;
  *) print -u2 'MEETING_BUILD_EDITION must be standard or compatibility'; exit 2 ;;
esac
if [[ "$MEETING_BUILD_EDITION" == compatibility ]]; then
  python3 scripts/build-whisper.py
fi
./scripts/build-summary-helper.sh "$configuration"
swift build -c "$configuration" --scratch-path ".build/$MEETING_BUILD_EDITION"
bin_dir="$(swift build -c "$configuration" --scratch-path ".build/$MEETING_BUILD_EDITION" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Replace the executable inode instead of truncating a binary mapped by a running recording.
cp "$bin_dir/MeetingIntelligence" "$app_path/Contents/MacOS/.MeetingIntelligence.next"
mv -f "$app_path/Contents/MacOS/.MeetingIntelligence.next" "$app_path/Contents/MacOS/MeetingIntelligence"
cp "$bin_dir/meeting" "$app_path/Contents/MacOS/.meeting.next"
mv -f "$app_path/Contents/MacOS/.meeting.next" "$app_path/Contents/MacOS/meeting"
cp build/meeting-summary "$app_path/Contents/MacOS/.meeting-summary.next"
mv -f "$app_path/Contents/MacOS/.meeting-summary.next" "$app_path/Contents/MacOS/meeting-summary"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum_system" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MIBuildEdition string $MEETING_BUILD_EDITION" "$app_path/Contents/Info.plist"
if [[ -n "${MEETING_APP_VERSION:-}" ]]; then
  if [[ ! "$MEETING_APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 'MEETING_APP_VERSION must use X.Y.Z format.'
    exit 2
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MEETING_APP_VERSION" "$app_path/Contents/Info.plist"
fi
if [[ -n "${MEETING_BUILD_NUMBER:-}" ]]; then
  if [[ ! "$MEETING_BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
    print -u2 'MEETING_BUILD_NUMBER must be numeric.'
    exit 2
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MEETING_BUILD_NUMBER" "$app_path/Contents/Info.plist"
fi
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_commit="$(git rev-parse --short HEAD 2>/dev/null || print uncommitted)"
/usr/libexec/PlistBuddy -c "Add :MIBuildTime string $build_time" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MICommit string $build_commit" "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp Sources/MeetingCore/Resources/TranscriptExport.html "$app_path/Contents/Resources/TranscriptExport.html"
cp Sources/MeetingCore/Resources/AppIcon.png "$app_path/Contents/Resources/AppIcon.png"
if [[ "$MEETING_BUILD_EDITION" == compatibility ]]; then
  cp build/whisper/runtime/meeting-whisper "$app_path/Contents/MacOS/.meeting-whisper.next"
  mv -f "$app_path/Contents/MacOS/.meeting-whisper.next" "$app_path/Contents/MacOS/meeting-whisper"
  mkdir -p "$app_path/Contents/Resources/Whisper"
  ditto build/whisper/runtime/Licenses "$app_path/Contents/Resources/Whisper/Licenses"
  cp build/whisper/runtime/ggml-base-q5_1.bin "$app_path/Contents/Resources/Whisper/ggml-base-q5_1.bin"
  cp Helpers/whisper/manifest.json "$app_path/Contents/Resources/Whisper/manifest.json"
else
  # Remove stale optional assets too, so an incremental build cannot leak models.
  rm -rf "$app_path/Contents/Resources/Whisper"
  rm -f "$app_path/Contents/MacOS/meeting-whisper"
fi
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
if [[ "$MEETING_BUILD_EDITION" == compatibility ]]; then
  codesign --force --sign "$signing_identity" "$app_path/Contents/MacOS/meeting-whisper"
fi
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --strict "$app_path"
python3 scripts/verify-app.py "$app_path"
# Refresh only this app's registration, leaving the user's Dock and other apps alone.
touch "$app_path"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$app_path"
fi
print "Built $app_path"
