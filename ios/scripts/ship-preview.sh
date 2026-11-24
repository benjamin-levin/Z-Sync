#!/bin/bash
# Personal Preview only. Uses the Shared General vault's headless TestFlight
# workflow; credentials and signing configuration remain on the build Mac.
set -euo pipefail
BUILD_NUMBER=${1:?Pass the next unused Preview TestFlight build number}
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${OUTPUT_DIR:-"$HOME/ci/zsync-login-repair/release-$BUILD_NUMBER"}
mkdir -p "$OUTPUT_DIR"
set -a
source "$HOME/.ios-ci/asc.env"
set +a
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
BUILD_KEYCHAIN="$HOME/Library/Keychains/ci.keychain-db"
TEAM_ID=$(awk '/^DEVELOPMENT_TEAM = / {print $3}' "$PROJECT_DIR/Config/Team.local.xcconfig")
test -n "$TEAM_ID"
security unlock-keychain -p "$(cat "$HOME/.ios-ci/keychain.pass")" "$BUILD_KEYCHAIN" >/dev/null 2>&1
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
cd "$PROJECT_DIR"
/opt/homebrew/bin/xcodegen generate > "$OUTPUT_DIR/generate.log" 2>&1
echo "Archiving Z-Sync Preview build $BUILD_NUMBER"
xcodebuild -project ZenCompanion.xcodeproj -scheme ZenCompanion -configuration Release \
  -destination generic/platform=iOS -archivePath "$OUTPUT_DIR/ZSyncPreview.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--keychain $BUILD_KEYCHAIN" "${AUTH[@]}" archive \
  > "$OUTPUT_DIR/archive.log" 2>&1 || { tail -30 "$OUTPUT_DIR/archive.log"; exit 1; }
APP="$OUTPUT_DIR/ZSyncPreview.xcarchive/Products/Applications/ZenCompanion.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")" = com.benjaminlevin.zsync.preview
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")" = "$BUILD_NUMBER"
codesign --verify --strict "$APP"
cat > "$OUTPUT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
echo "Uploading Z-Sync Preview build $BUILD_NUMBER"
xcodebuild -exportArchive -archivePath "$OUTPUT_DIR/ZSyncPreview.xcarchive" \
  -exportOptionsPlist "$OUTPUT_DIR/ExportOptions.plist" -exportPath "$OUTPUT_DIR/export" \
  "${AUTH[@]}" > "$OUTPUT_DIR/export.log" 2>&1 || { tail -30 "$OUTPUT_DIR/export.log"; exit 1; }
grep -q 'Upload succeeded' "$OUTPUT_DIR/export.log"
echo "Uploaded build $BUILD_NUMBER; verify processing and tester availability in App Store Connect."
