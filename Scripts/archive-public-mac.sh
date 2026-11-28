#!/bin/bash
# Signed Mac Catalyst archive for the Mac App Store. No upload is performed.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Xcode on a Mac is required.' >&2; exit 1; }
: "${KOAJENT_TEAM_ID:?Set KOAJENT_TEAM_ID to the KoAjent organization Team ID.}"
[[ "${PARANO1D_MAC_ACCEPTED:-}" == 1 ]] || { echo 'Test the Mac app (Scripts/build-mac.sh), then set PARANO1D_MAC_ACCEPTED=1.' >&2; exit 1; }
: "${PARANO1D_PRIVACY_POLICY_URL:?Set PARANO1D_PRIVACY_POLICY_URL to the published https privacy policy.}"
: "${PARANO1D_EXPORT_RESULT:?Set PARANO1D_EXPORT_RESULT to exempt or approved, matching App Store Connect.}"
case "$PARANO1D_EXPORT_RESULT" in
  exempt) compliance=(INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO) ;;
  approved) : "${PARANO1D_EXPORT_COMPLIANCE_CODE:?Enter the approved compliance code.}"
            compliance=(INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=YES "INFOPLIST_KEY_ITSEncryptionExportComplianceCode=$PARANO1D_EXPORT_COMPLIANCE_CODE") ;;
  *) echo 'Use exempt or approved.' >&2; exit 1 ;;
esac
python3 Scripts/check-public-edition.py
[[ -d Native/ParanoidCore.xcframework/ios-arm64_x86_64-maccatalyst && -d Node/ParanoidNode.xcframework/ios-arm64_x86_64-maccatalyst ]] || { echo 'Run bash Scripts/build-mac.sh first.' >&2; exit 1; }
python3 Scripts/mac-spec.py
xcodegen generate --spec project-public-mac.yml
mkdir -p TestResults
archive="$PWD/TestResults/Parano1dPublic-Mac.xcarchive"
xcodebuild -project Parano1dPublicMac.xcodeproj -scheme Parano1dPublicMac -destination 'generic/platform=macOS,variant=Mac Catalyst' -configuration Release \
  -archivePath "$archive" DEVELOPMENT_TEAM="$KOAJENT_TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
  PARANO1D_PRIVACY_POLICY_URL="$PARANO1D_PRIVACY_POLICY_URL" PARANO1D_TERMS_URL="${PARANO1D_TERMS_URL:-}" PARANO1D_SUPPORT_URL="${PARANO1D_SUPPORT_URL:-}" \
  "${compliance[@]}" archive 2>&1 | tee TestResults/mac-archive.log
bash Scripts/check-release-bundle.sh "$archive" || { echo "Archive failed the release check; do not upload it." >&2; exit 1; }
printf '%s\n' "Mac archive created: $archive" 'Upload it from Xcode Organizer (Mac App Store Connect). No upload was performed.'
