#!/bin/bash
# Builds the Mac Catalyst app (Intel and Apple silicon) for local testing. No upload.
set -euo pipefail
set -o pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Xcode on a Mac is required.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen first: brew install xcodegen' >&2; exit 1; }
# Adds the Mac Catalyst slices to both Rust frameworks (keeps the iPhone slices).
PARANO1D_MAC_CATALYST=1 bash Scripts/build-native.sh
PARANO1D_MAC_CATALYST=1 bash Scripts/build-node.sh
python3 Scripts/check-public-edition.py
python3 Scripts/mac-spec.py
xcodegen generate --spec project-public-mac.yml
mkdir -p TestResults
# The wallet key lives in the data-protection Keychain, which macOS only opens for signed apps.
if [[ -n "${KOAJENT_TEAM_ID:-}" ]]; then
  signing=(DEVELOPMENT_TEAM="$KOAJENT_TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -allowProvisioningDeviceRegistration)
else
  echo 'KOAJENT_TEAM_ID is not set: building unsigned. The app will open, but creating or unlocking a wallet needs a signed build.' >&2
  signing=(CODE_SIGNING_ALLOWED=NO)
fi
build(){ xcodebuild -project Parano1dPublicMac.xcodeproj -scheme Parano1dPublicMac \
  -destination 'platform=macOS,variant=Mac Catalyst' -configuration Debug \
  -derivedDataPath "$PWD/DerivedData-Mac" "$@" build 2>&1 | tee TestResults/mac-build.log; }
if ! build "${signing[@]}"; then
  if grep -qE "isn't registered in your developer account|No profiles for|requires a provisioning profile" TestResults/mac-build.log; then
    # This Mac is not registered for development signing yet. The code still has to compile,
    # so check it unsigned; register the Mac (Xcode → Settings → Accounts, or the developer
    # website's Devices list) to get a signed Mac app that can open a wallet.
    echo 'Signing for this Mac is not set up yet; building unsigned to check the code.' >&2
    build CODE_SIGNING_ALLOWED=NO
  else
    exit 1
  fi
fi
app="$(find "$PWD/DerivedData-Mac/Build/Products/Debug-maccatalyst" -maxdepth 1 -name '*.app' | head -1)"
printf '%s\n' "Mac app built: $app" "Open it with: open \"$app\"" "No upload was performed."
