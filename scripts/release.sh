#!/bin/bash
# Builds a release of Runlight for Mac, from a clean main, ready to publish:
#
#   scripts/release.sh 0.1.0              everything, notarized
#   scripts/release.sh 0.1.0 --dry-run    the same without notarizing, committing, or tagging
#
# It sets the version, runs the checks, archives and signs with the Developer ID certificate,
# notarizes and staples the app and the DMG, and writes the update feed. It commits and tags the
# release, and never pushes or publishes: it prints the commands for that at the end.
#
# Needs: the Developer ID Application certificate, a notarytool profile (NOTARY_PROFILE, default
# runlight-notary, made once with `xcrun notarytool store-credentials runlight-notary`), the
# Sparkle key for runlight-mac in the Keychain, create-dmg, and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh <version> [--dry-run], like scripts/release.sh 0.1.0" >&2
  exit 1
fi
PROFILE="${NOTARY_PROFILE:-runlight-notary}"
TEAM=JV2VUU6R4W
IDENTITY="Developer ID Application"
OUT="build/release/$VERSION"
ARCHIVES="build/release/archives"
SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
DMG="$ARCHIVES/Runlight-$VERSION.dmg"
DOWNLOADS="https://github.com/runlightsh/runlight-mac/releases/download/v$VERSION/"

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "Checking where we are"
if [ -n "$(git status --porcelain)" ]; then echo "The working tree has changes; commit or stash them first." >&2; exit 1; fi
if [ "$(git branch --show-current)" != "main" ]; then echo "Release from main." >&2; exit 1; fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then echo "v$VERSION is already tagged." >&2; exit 1; fi
security find-identity -v -p codesigning | grep -q "$IDENTITY: .*($TEAM)" || { echo "No $IDENTITY certificate for $TEAM in the Keychain." >&2; exit 1; }
if ! $DRY_RUN; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "No notarytool profile called $PROFILE. Make one with: xcrun notarytool store-credentials $PROFILE --apple-id <you> --team-id $TEAM" >&2; exit 1; }
fi

step "Setting the version to $VERSION"
# The build number only ever rises, as Sparkle compares it: the number of commits, plus one for the release's own.
BUILD=$(( $(git rev-list --count HEAD) + 1 ))
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
restore() { $DRY_RUN && git checkout -- project.yml 2>/dev/null || true; }
trap restore EXIT

step "Running the checks"
scripts/check.sh

step "Archiving and signing"
rm -rf "$OUT" && mkdir -p "$OUT" "$ARCHIVES"
xcodebuild archive -project Runlight.xcodeproj -scheme Runlight -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$OUT/Runlight.xcarchive" -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Runlight.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet
APP="$OUT/export/Runlight.app"
codesign --verify --deep --strict --verbose=1 "$APP"

if ! $DRY_RUN; then
  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/Runlight.zip"
  xcrun notarytool submit "$OUT/Runlight.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
scripts/dmg/render.sh "$OUT/background.tiff"
rm -f "$DMG"
create-dmg --volname "Runlight" --background "$OUT/background.tiff" --window-size 660 400 \
  --icon-size 112 --icon "Runlight.app" 170 190 --app-drop-link 490 190 --hide-extension "Runlight.app" \
  --codesign "$IDENTITY" --no-internet-enable "$DMG" "$APP"

if ! $DRY_RUN; then
  step "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

step "Writing the update feed"
"$SPARKLE_BIN/generate_appcast" --account runlight-mac --download-url-prefix "$DOWNLOADS" \
  --link "https://runlight.sh/mac/" -o "$OUT/appcast.xml" "$ARCHIVES"

if $DRY_RUN; then
  step "Dry run done"
  echo "DMG: $DMG (not notarized). The version in project.yml is put back."
  exit 0
fi

step "Committing and tagging"
trap - EXIT
git add project.yml
git commit -q -m "Release $VERSION"
git tag "v$VERSION"

# The same DMG under a name that never changes, for releases/latest/download/Runlight.dmg (which the
# download link on runlight.sh/mac goes to). Kept out of $ARCHIVES, where generate_appcast would list it.
cp "$DMG" "$OUT/Runlight.dmg"

# The Homebrew cask, in a checkout of github.com/runlightsh/homebrew-tap next to this repo.
CASK=../homebrew-tap/Casks/runlight.rb
if [ -f "$CASK" ]; then
  step "Updating the Homebrew cask"
  SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  git -C ../homebrew-tap commit -q -am "Runlight $VERSION"
  CASK_STEP="git -C ../homebrew-tap push   (after the GitHub release, so the cask's DMG exists)"
else
  CASK_STEP="Clone git@github.com:runlightsh/homebrew-tap.git next to this repo, then set version \"$VERSION\" and sha256 \"$(shasum -a 256 "$DMG" | cut -d' ' -f1)\" in Casks/runlight.rb, commit, and push"
fi

step "Ready. To publish:"
cat <<NEXT
  git push origin main v$VERSION
  gh release create v$VERSION "$DMG" "$OUT/Runlight.dmg" --repo runlightsh/runlight-mac --title "Runlight for Mac $VERSION" --notes "..."
  cp "$OUT/appcast.xml" ../runlight-website/site/src/root/mac/appcast.xml   (then commit and push the website)
  $CASK_STEP
NEXT
